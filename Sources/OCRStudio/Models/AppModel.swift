import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

/// UI-facing model of a single page in the working document.
@MainActor
@Observable
final class PageVM: Identifiable {
    let id = UUID()
    let originalImage: SendableImage   // untouched source; re-run the pipeline from here
    var image: SendableImage           // image OCR ran on (display + box + PDF source)
    var dpi: Double
    var sourceName: String
    var cropToContent: Bool            // re-apply content crop on re-run (scanned pages)

    /// Recognized text — replaced whenever OCR (re)runs. Edits flow into editedText.
    ///
    /// Only tracks the new recognition when the user hasn't corrected the text.
    /// The inspector promises those corrections drive the exports, so re-running
    /// OCR must not silently discard them.
    var ocr: OCRPageResult? {
        didSet {
            if editedText == (oldValue?.fullText ?? "") {
                editedText = ocr?.fullText ?? ""
            }
        }
    }
    /// User-editable text shown/edited in the inspector and used by text exports.
    var editedText: String = ""

    init(originalImage: SendableImage, image: SendableImage, dpi: Double,
         sourceName: String, ocr: OCRPageResult?, cropToContent: Bool) {
        self.originalImage = originalImage
        self.image = image
        self.dpi = dpi
        self.sourceName = sourceName
        self.ocr = ocr
        self.cropToContent = cropToContent
        self.editedText = ocr?.fullText ?? ""   // didSet doesn't fire from init
    }

    convenience init(_ p: ProcessedPage) {
        self.init(originalImage: p.original, image: p.image, dpi: p.dpi,
                  sourceName: p.sourceName, ocr: p.ocr, cropToContent: p.cropToContent)
    }

    var nsImage: NSImage {
        NSImage(cgImage: image.cgImage, size: NSSize(width: image.width, height: image.height))
    }

    var processed: ProcessedPage? {
        guard let ocr else { return nil }
        return ProcessedPage(image: image, original: originalImage, dpi: dpi,
                             ocr: ocr, sourceName: sourceName, cropToContent: cropToContent)
    }
}

/// Top-level app state and the bridge between the UI and the services.
@MainActor
@Observable
final class AppModel {
    var pages: [PageVM] = []
    var selectedPageID: PageVM.ID?
    var status: String = "Ready"
    var isBusy: Bool = false
    var isWatching: Bool = false

    var settings: Settings = .load() {
        didSet {
            scheduleSettingsSave()
            if oldValue.watchFolder != settings.watchFolder, isWatching {
                configureWatch(folder: settings.watchFolder)
            }
        }
    }

    // Scan options bound by the UI.
    var scanSource: ScanJobOptions.Source = .flatbed
    var scanPageSize: ScanJobOptions.PageSize = .letter
    var scanDPI: Int = 300
    var scanColor: Bool = true
    var scanDuplex: Bool = false

    @ObservationIgnored let scanner = ScannerService()
    @ObservationIgnored private let jobs = JobManager()
    @ObservationIgnored private let watcher = WatchFolderService()
    @ObservationIgnored private var watchRequestID = 0
    @ObservationIgnored private var watchConfigurationTask: Task<Void, Never>?
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    /// The in-flight `runJob` task, retained so the user can cancel it.
    @ObservationIgnored private var jobTask: Task<Void, Never>?

    var selectedPage: PageVM? { pages.first { $0.id == selectedPageID } }
    var hasPages: Bool { !pages.isEmpty }
    var ocrResults: [OCRPageResult] { pages.compactMap(\.ocr) }

    // MARK: Open files

    func openFilePicker() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FileIngestor.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        if panel.runModal() == .OK {
            importFiles(panel.urls)
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isBusy else { return }
        runJob("Reading \(urls.count) file(s)…") { [settings] in
            var newPages: [PageVM] = []
            var failed: [String] = []
            for url in urls {
                try Task.checkCancellation()
                // Keep what succeeded — one corrupt file shouldn't cost the user
                // every other page in the selection.
                do {
                    let processed = try await self.jobs.process(url: url, settings: settings)
                    newPages.append(contentsOf: processed.map(PageVM.init))
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            self.pages.append(contentsOf: newPages)
            if self.selectedPageID == nil { self.selectedPageID = self.pages.first?.id }
            return "Loaded \(newPages.count) page(s)"
                + (failed.isEmpty ? ""
                   : " · skipped \(failed.count): \(failed.joined(separator: ", "))")
        }
    }

    // MARK: Re-run OCR with current settings

    /// Re-run the full pipeline (preprocess + OCR) from each page's untouched
    /// original using the current settings, so changing preprocessing/OCR options
    /// takes effect without compounding earlier preprocessing.
    func rerunOCR() {
        let snapshot = pages.map { ($0.id, $0.originalImage, $0.dpi, $0.sourceName, $0.cropToContent) }
        guard !snapshot.isEmpty else { return }
        runJob("Recognizing text…") { [settings] in
            var updates: [(PageVM.ID, ProcessedPage)] = []
            var failed = 0
            for (id, original, dpi, name, crop) in snapshot {
                try Task.checkCancellation()
                do {
                    let p = try await self.jobs.processImage(original, dpi: dpi, name: name,
                                                             settings: settings,
                                                             cropToContent: crop)
                    updates.append((id, p))
                } catch {
                    failed += 1   // leave that page's previous result intact
                }
            }
            for (id, p) in updates {
                if let page = self.pages.first(where: { $0.id == id }) {
                    page.image = p.image    // keep boxes/overlay/PDF in sync with the new OCR
                    page.ocr = p.ocr
                }
            }
            return "OCR complete on \(updates.count) page(s)"
                + (failed > 0 ? " · \(failed) failed" : "")
        }
    }

    // MARK: Scanning

    func startBrowsing() { scanner.startBrowsing() }

    /// Release the ICA device browser — it polls the network for the whole
    /// process lifetime otherwise.
    func stopBrowsing() { scanner.stopBrowsing() }

    func cancelScan() { scanner.cancel() }

    /// Epson's own scanning app, if installed (ScanSmart preferred — it scans
    /// straight to a file). Used as a fallback when macOS/ImageCaptureCore can't
    /// see the scanner but Epson's proprietary driver can.
    var epsonScannerAppURL: URL? {
        ["/Applications/Epson Software/Epson ScanSmart.app",
         "/Applications/Epson Software/Epson Scan 2.app"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func launchEpsonScanner() {
        guard let url = epsonScannerAppURL else {
            status = "Epson scanning software not found in /Applications/Epson Software"
            return
        }
        NSWorkspace.shared.open(url)
        let name = url.deletingPathExtension().lastPathComponent
        status = "Opened \(name) — save scans into your Watch Folder to auto-OCR them"
    }

    func scan(scannerID: String) {
        guard !isBusy else { return }
        var options = ScanJobOptions()
        options.source = scanSource
        options.pageSize = scanPageSize
        options.dpi = scanDPI
        options.color = scanColor
        options.duplex = scanDuplex

        var scannedURLs: [URL] = []
        isBusy = true
        status = "Scanning…"
        scanner.scan(scannerID: scannerID, options: options,
                     onPage: { url in scannedURLs.append(url) },
                     onComplete: { [weak self] error in
            guard let self else { return }
            if let error {
                self.removeScanFiles(scannedURLs)
                self.isBusy = false
                self.status = "Scan failed: \(error.localizedDescription)"
                return
            }
            self.status = "Recognizing \(scannedURLs.count) scanned page(s)…"
            Task { [settings = self.settings] in
                defer { self.removeScanFiles(scannedURLs) }
                var newPages: [PageVM] = []
                var blanks = 0
                var failed = 0
                for url in scannedURLs {
                    // Keep the sheets that processed — a single bad capture
                    // shouldn't discard the rest of the feeder run.
                    do {
                        let processed = try await self.jobs.process(
                            url: url, settings: settings,
                            cropToContent: settings.autoCropScannedPages)
                        for page in processed {
                            if settings.skipBlankPages, await self.jobs.isBlankPage(page) {
                                blanks += 1
                            } else {
                                newPages.append(PageVM(page))
                            }
                        }
                    } catch {
                        failed += 1
                    }
                }
                self.pages.append(contentsOf: newPages)
                if self.selectedPageID == nil { self.selectedPageID = self.pages.first?.id }
                self.status = "Scanned \(newPages.count) page(s)"
                    + (blanks > 0 ? " · skipped \(blanks) blank" : "")
                    + (failed > 0 ? " · \(failed) failed" : "")
                self.isBusy = false
            }
        })
    }

    // MARK: Watch folder

    func toggleWatch() {
        if isWatching { stopWatch() } else { startWatch() }
    }

    private func startWatch() {
        guard let folder = settings.watchFolder else {
            status = "Choose a watch folder in Settings first"
            return
        }
        configureWatch(folder: folder)
    }

    private func stopWatch() {
        configureWatch(folder: nil)
    }

    private func configureWatch(folder: URL?) {
        watchRequestID += 1
        let requestID = watchRequestID
        let previousTask = watchConfigurationTask
        previousTask?.cancel()
        isWatching = false
        status = folder == nil ? "Stopped watching" : "Starting watch…"

        watchConfigurationTask = Task {
            _ = await previousTask?.result
            guard !Task.isCancelled, requestID == watchRequestID else { return }
            await watcher.stop()
            guard !Task.isCancelled, requestID == watchRequestID else { return }
            guard let folder else { return }

            await watcher.setHandler { [weak self] url in
                guard let self else { return false }
                let settings = self.settings
                if !self.isBusy {
                    self.status = "Auto-processing \(url.lastPathComponent)…"
                }
                do {
                    let pdf = try await self.jobs.autoProcess(url: url, settings: settings)
                    if !self.isBusy { self.status = "Wrote \(pdf.lastPathComponent)" }
                    return true
                } catch {
                    if !self.isBusy {
                        self.status = "Auto-process failed: \(error.localizedDescription) · will retry"
                    }
                    return false
                }
            }

            do {
                try await watcher.start(folder: folder)
                guard !Task.isCancelled, requestID == watchRequestID else {
                    await watcher.stop()
                    return
                }
                isWatching = true
                status = "Watching \(folder.lastPathComponent)"
            } catch {
                guard !Task.isCancelled, requestID == watchRequestID else { return }
                isWatching = false
                status = "Could not watch folder: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Exports

    func exportSearchablePDF() {
        let processed = pages.compactMap(\.processed)
        guard !processed.isEmpty else { return }
        guard let url = savePanel(suggested: "Scan-ocr.pdf", type: .pdf) else { return }
        runJob("Writing searchable PDF…") {
            try await self.jobs.writeSearchablePDF(processed, to: url)
            return "Saved \(url.lastPathComponent)"
        }
    }

    /// Per-page edited text (reflects the user's corrections in the inspector).
    var editedPages: [String] { pages.map(\.editedText) }

    func exportWord() {
        let type = UTType(filenameExtension: "docx") ?? .data
        guard let url = savePanel(suggested: "Document.docx", type: type) else { return }
        let pageText = editedPages
        runJob("Writing Word document…") {
            let data = try await Task.detached {
                try RichTextExport.wordData(from: pageText)
            }.value
            try await Task.detached {
                try data.write(to: url, options: .atomic)
            }.value
            return "Saved \(url.lastPathComponent)"
        }
    }

    func exportTextPDF() {
        guard let url = savePanel(suggested: "Document.pdf", type: .pdf) else { return }
        let pageText = editedPages
        runJob("Writing PDF…") {
            try await Task.detached {
                try RichTextExport.writeTextPDF(pages: pageText, to: url)
            }.value
            return "Saved \(url.lastPathComponent)"
        }
    }

    func exportText() {
        guard let url = savePanel(suggested: "Document.txt", type: .plainText) else { return }
        writeString(editedPages.joined(separator: "\n\n\u{000C}\n"), to: url)
    }

    func exportMarkdown() {
        let type = UTType(filenameExtension: "md") ?? .plainText
        guard let url = savePanel(suggested: "Scan.md", type: type) else { return }
        writeString(Exporters.markdown(ocrResults), to: url)
    }

    func exportJSON() {
        guard let url = savePanel(suggested: "Scan.json", type: .json) else { return }
        let results = ocrResults
        runJob("Writing JSON…") {
            let data = try await Task.detached {
                try Exporters.json(results)
            }.value
            try await Task.detached {
                try data.write(to: url, options: .atomic)
            }.value
            return "Saved \(url.lastPathComponent)"
        }
    }

    func clear() {
        guard !isBusy else {
            status = "Wait for the current operation to finish before clearing"
            return
        }
        pages.removeAll()
        selectedPageID = nil
        status = "Cleared"
    }

    // MARK: Page management (batch curation)

    func deletePage(_ id: PageVM.ID) {
        pages.removeAll { $0.id == id }
        if selectedPageID == id { selectedPageID = pages.first?.id }
    }

    func deletePages(atOffsets offsets: IndexSet) {
        let removed = Set(offsets.map { pages[$0].id })
        pages.remove(atOffsets: offsets)
        if let sel = selectedPageID, removed.contains(sel) { selectedPageID = pages.first?.id }
    }

    func movePages(fromOffsets: IndexSet, toOffset: Int) {
        pages.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    // MARK: Helpers

    private func writeString(_ string: String, to url: URL) {
        runJob("Saving…") {
            try await Task.detached {
                try string.write(to: url, atomically: true, encoding: .utf8)
            }.value
            return "Saved \(url.lastPathComponent)"
        }
    }

    private func removeScanFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Coalesce persistence: `settings` mutates once per keystroke in the Settings
    /// window, and each write is a full JSON encode into `UserDefaults`.
    private func scheduleSettingsSave() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [settings] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            settings.save()
        }
    }

    private func savePanel(suggested: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Run async work with busy/status bookkeeping. The closure returns a status string.
    private func runJob(_ startStatus: String, _ work: @escaping () async throws -> String) {
        guard !isBusy else {
            status = "Another operation is already in progress"
            return
        }
        isBusy = true
        status = startStatus
        jobTask = Task {
            do {
                let result = try await work()
                self.status = result
            } catch is CancellationError {
                self.status = "Cancelled"
            } catch {
                self.status = "Error: \(error.localizedDescription)"
            }
            self.isBusy = false
            self.jobTask = nil
        }
    }

    /// Abort whatever is running — a long batch would otherwise lock every
    /// control with no way out.
    func cancelJob() {
        if scanner.isScanning { scanner.cancel() }
        jobTask?.cancel()
    }

    /// Tear down background work when the window goes away.
    func shutDown() {
        jobTask?.cancel()
        settingsSaveTask?.cancel()
        settings.save()          // flush any debounced write
        watchConfigurationTask?.cancel()
        scanner.cancel()
        scanner.stopBrowsing()
        let watcher = self.watcher
        Task { await watcher.stop() }
    }
}
