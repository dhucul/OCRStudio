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
    var ocr: OCRPageResult? {
        didSet { editedText = ocr?.fullText ?? "" }
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
        didSet { settings.save() }
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

    var selectedPage: PageVM? { pages.first { $0.id == selectedPageID } }
    var hasPages: Bool { !pages.isEmpty }
    var ocrResults: [OCRPageResult] { pages.compactMap(\.ocr) }

    // MARK: Open files

    func openFilePicker() {
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
        guard !urls.isEmpty else { return }
        runJob("Reading \(urls.count) file(s)…") { [settings] in
            var newPages: [PageVM] = []
            for url in urls {
                let processed = await self.jobs.process(url: url, settings: settings)
                newPages.append(contentsOf: processed.map(PageVM.init))
            }
            await MainActor.run {
                self.pages.append(contentsOf: newPages)
                if self.selectedPageID == nil { self.selectedPageID = self.pages.first?.id }
            }
            return "Loaded \(newPages.count) page(s)"
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
            for (id, original, dpi, name, crop) in snapshot {
                let p = await self.jobs.processImage(original, dpi: dpi, name: name,
                                                     settings: settings, cropToContent: crop)
                updates.append((id, p))
            }
            await MainActor.run {
                for (id, p) in updates {
                    if let page = self.pages.first(where: { $0.id == id }) {
                        page.image = p.image    // keep boxes/overlay/PDF in sync with the new OCR
                        page.ocr = p.ocr
                    }
                }
            }
            return "OCR complete"
        }
    }

    // MARK: Scanning

    func startBrowsing() { scanner.startBrowsing() }

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
                self.isBusy = false
                self.status = "Scan failed: \(error.localizedDescription)"
                return
            }
            self.status = "Recognizing \(scannedURLs.count) scanned page(s)…"
            Task { [settings = self.settings] in
                var newPages: [PageVM] = []
                for url in scannedURLs {
                    let processed = await self.jobs.process(
                        url: url, settings: settings,
                        cropToContent: settings.autoCropScannedPages)
                    newPages.append(contentsOf: processed.map(PageVM.init))
                }
                self.pages.append(contentsOf: newPages)
                if self.selectedPageID == nil { self.selectedPageID = self.pages.first?.id }
                self.isBusy = false
                self.status = "Scanned \(newPages.count) page(s)"
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
        watcher.onFile = { [weak self] url in
            guard let self else { return }
            self.status = "Auto-processing \(url.lastPathComponent)…"
            Task { [settings = self.settings] in
                do {
                    let pdf = try await self.jobs.autoProcess(url: url, settings: settings)
                    self.status = "Wrote \(pdf.lastPathComponent)"
                } catch {
                    self.status = "Auto-process failed: \(error.localizedDescription)"
                }
            }
        }
        watcher.start(folder: folder)
        isWatching = true
        status = "Watching \(folder.lastPathComponent)"
    }

    private func stopWatch() {
        watcher.stop()
        isWatching = false
        status = "Stopped watching"
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
        runJob("Writing Word document…") {
            let data = RichTextExport.wordData(from: self.editedPages)
            try data.write(to: url)
            return "Saved \(url.lastPathComponent)"
        }
    }

    func exportTextPDF() {
        guard let url = savePanel(suggested: "Document.pdf", type: .pdf) else { return }
        runJob("Writing PDF…") {
            try RichTextExport.writeTextPDF(pages: self.editedPages, to: url)
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
        runJob("Writing JSON…") {
            let data = try Exporters.json(self.ocrResults)
            try data.write(to: url)
            return "Saved \(url.lastPathComponent)"
        }
    }

    func clear() {
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
            try string.write(to: url, atomically: true, encoding: .utf8)
            return "Saved \(url.lastPathComponent)"
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
        isBusy = true
        status = startStatus
        Task {
            do {
                let result = try await work()
                self.status = result
            } catch {
                self.status = "Error: \(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }
}
