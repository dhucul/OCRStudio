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
    var cropToContent: Bool
    var isScanned: Bool = false

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
        self.isScanned = p.isScanned
    }

    var nsImage: NSImage {
        NSImage(cgImage: image.cgImage, size: NSSize(width: image.width, height: image.height))
    }

    var processed: ProcessedPage? {
        guard let ocr else { return nil }
        return ProcessedPage(image: image, original: originalImage, dpi: dpi,
                             ocr: ocr, sourceName: sourceName, cropToContent: cropToContent,
                             isScanned: isScanned)
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
    var watchRequested: Bool = false
    var recoveryFiles: [URL] = []
    @ObservationIgnored private var isShuttingDown = false

    var settings: Settings = .load() {
        didSet {
            scheduleSettingsSave()
            if oldValue.watchFolder != settings.watchFolder, watchRequested {
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

    init() {
        // Captures survive cancellation, crashes and app restarts.
        if let files = FileManager.default.enumerator(at: ScannerService.recoveryDirectory,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) {
            recoveryFiles = files.compactMap { $0 as? URL }.filter {
                ["tif", "tiff"].contains($0.pathExtension.lowercased())
            }
        }
    }

    var selectedPage: PageVM? { pages.first { $0.id == selectedPageID } }
    var hasPages: Bool { !pages.isEmpty }
    var ocrResults: [OCRPageResult] { pages.compactMap(\.ocr) }
    private var retainedBytes: Int { pages.compactMap(\.processed).reduce(0) { $0 + $1.retainedBytes } }

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
            var loaded = 0
            var failures: [String] = []
            for url in urls {
                try Task.checkCancellation()
                do {
                    let report = try await self.jobs.processReport(
                        url: url, settings: settings,
                        maximumRetainedBytes: RasterBudget.maximumBytes - self.retainedBytes)
                    try Task.checkCancellation()
                    self.pages.append(contentsOf: report.pages.map(PageVM.init))
                    loaded += report.pages.count
                    failures.append(contentsOf: report.failures.map { "\(url.lastPathComponent): \($0)" })
                    if self.selectedPageID == nil { self.selectedPageID = self.pages.first?.id }
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            return "Loaded \(loaded) page(s)" + (failures.isEmpty ? "" : " · Incomplete: " + failures.joined(separator: "; "))
        }
    }

    // MARK: Re-run OCR with current settings

    /// Re-run the full pipeline (preprocess + OCR) from each page's untouched
    /// original using the current settings, so changing preprocessing/OCR options
    /// takes effect without compounding earlier preprocessing.
    func rerunOCR() {
        let snapshot = pages.map { ($0.id, $0.originalImage, $0.dpi, $0.sourceName, $0.cropToContent, $0.isScanned) }
        guard !snapshot.isEmpty else { return }
        runJob("Recognizing text…") { [settings] in
            var completed = 0
            var failures: [String] = []
            for (id, original, dpi, name, previousCrop, scanned) in snapshot {
                try Task.checkCancellation()
                do {
                    let crop = scanned ? settings.autoCropScannedPages : previousCrop
                    let p = try await self.jobs.processImage(original, dpi: dpi, name: name,
                                                             settings: settings, cropToContent: crop)
                    try Task.checkCancellation()
                    if let page = self.pages.first(where: { $0.id == id }) {
                        let oldBytes = page.processed?.retainedBytes ?? 0
                        guard self.retainedBytes - oldBytes + p.retainedBytes <= RasterBudget.maximumBytes else {
                            throw PipelineError.memoryLimit(URL(fileURLWithPath: name))
                        }
                        page.image = p.image
                        page.ocr = p.ocr
                        page.cropToContent = crop
                        completed += 1
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append(error.localizedDescription) }
            }
            return "OCR complete on \(completed) page(s)"
                + (failures.isEmpty ? "" : " · Failed: " + failures.joined(separator: "; "))
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

        let scanSettings = settings
        var scannedURLs: [URL] = []
        isBusy = true
        status = "Scanning…"
        scanner.scan(scannerID: scannerID, options: options,
                     onPage: { url in scannedURLs.append(url) },
                     onComplete: { [weak self] error in
            self?.finishScan(captured: scannedURLs, error: error, settings: scanSettings)
        })
    }

    /// Captures are already durable in Application Support. Only remove a source
    /// after all its readable pages have been committed without any page failures.
    func finishScan(captured urls: [URL], error: Error?, settings: Settings) {
        recoveryFiles.append(contentsOf: urls.filter { !recoveryFiles.contains($0) })
        isBusy = false
        guard !isShuttingDown else { return }
        if error is CancellationError {
            status = "Scan cancelled · \(urls.count) capture(s) kept for recovery"
            return
        }
        guard !urls.isEmpty else {
            status = error.map { "Scan failed: \($0.localizedDescription)" } ?? "No pages captured"
            return
        }
        let scanWarning = error.map { " · Scanner stopped: \($0.localizedDescription)" } ?? ""
        runJob("Recognizing \(urls.count) captured page(s)…") {
            var loaded = 0
            var blanks = 0
            var failures: [String] = []
            for url in urls {
                try Task.checkCancellation()
                do {
                    let report = try await self.jobs.processReport(
                        url: url, settings: settings, cropToContent: settings.autoCropScannedPages,
                        isScanned: true, maximumRetainedBytes: RasterBudget.maximumBytes - self.retainedBytes)
                    var accepted: [ProcessedPage] = []
                    for page in report.pages {
                        if settings.skipBlankPages, await self.jobs.isBlankPage(page) { blanks += 1 }
                        else { accepted.append(page) }
                    }
                    try Task.checkCancellation()
                    self.pages.append(contentsOf: accepted.map(PageVM.init))
                    loaded += accepted.count
                    if self.selectedPageID == nil { self.selectedPageID = self.pages.first?.id }
                    failures.append(contentsOf: report.failures)
                    if report.failures.isEmpty {
                        self.removeScanFiles([url])
                        self.recoveryFiles.removeAll { $0 == url }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append(error.localizedDescription) }
            }
            return "Recovered \(loaded) page(s) · \(blanks) blank" + scanWarning
                + (failures.isEmpty ? "" : " · Captures kept: " + failures.joined(separator: "; "))
        }
    }

    func revealRecoverableScans() {
        NSWorkspace.shared.activateFileViewerSelecting(recoveryFiles)
    }

    // MARK: Watch folder

    func toggleWatch() {
        if watchRequested { stopWatch() } else { startWatch() }
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
        watchRequested = folder != nil
        watchRequestID += 1
        let requestID = watchRequestID
        let previousTask = watchConfigurationTask
        previousTask?.cancel()
        isWatching = false
        status = folder == nil ? "Stopping watch…" : "Starting watch…"

        watchConfigurationTask = Task {
            _ = await previousTask?.result
            guard !Task.isCancelled, requestID == watchRequestID else { return }
            await watcher.stop()
            guard !Task.isCancelled, requestID == watchRequestID else { return }
            guard let folder else { status = "Stopped watching"; return }

            await watcher.setHandler { [weak self] url in
                guard let self, !self.isShuttingDown, requestID == self.watchRequestID,
                      !Task.isCancelled else { return false }
                let settings = self.settings
                if !self.isBusy {
                    self.status = "Auto-processing \(url.lastPathComponent)…"
                }
                do {
                    let pdf = try await self.jobs.autoProcess(url: url, settings: settings)
                    guard !Task.isCancelled, requestID == self.watchRequestID, !self.isShuttingDown else { return false }
                    if !self.isBusy { self.status = "Wrote \(pdf.lastPathComponent)" }
                    return true
                } catch {
                    guard !Task.isCancelled, requestID == self.watchRequestID, !self.isShuttingDown else { return false }
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
                watchRequested = false
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
            let data = try await cancellableWork {
                try RichTextExport.wordData(from: pageText)
            }
            try await cancellableWork {
                try AtomicFile.write(data, to: url)
            }
            return "Saved \(url.lastPathComponent)"
        }
    }

    func exportTextPDF() {
        guard let url = savePanel(suggested: "Document.pdf", type: .pdf) else { return }
        let pageText = editedPages
        runJob("Writing PDF…") {
            try await cancellableWork {
                try RichTextExport.writeTextPDF(pages: pageText, to: url)
            }
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
            let data = try await cancellableWork {
                try Exporters.json(results)
            }
            try await cancellableWork {
                try AtomicFile.write(data, to: url)
            }
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
            try await cancellableWork {
                try AtomicFile.write(Data(string.utf8), to: url)
            }
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
                try Task.checkCancellation()
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
        isShuttingDown = true
        watchRequestID += 1
        watchRequested = false
        isWatching = false
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
