import Foundation
import CoreGraphics

/// One fully-processed page. `image` is the (possibly preprocessed) image that OCR
/// ran on — and therefore the one the boxes and PDF visible layer must use.
/// `original` is the untouched source, kept so the pipeline can be re-run from
/// scratch when settings change (without compounding preprocessing).
struct ProcessedPage: Sendable {
    var image: SendableImage
    var original: SendableImage
    var dpi: Double
    var ocr: OCRPageResult
    var sourceName: String
}

/// Orchestrates the ingest → preprocess → OCR pipeline. Shared by the interactive
/// "open files" path, batch processing, and the watch folder.
actor JobManager {

    /// Suffix added to auto-generated outputs. Shared so the watch folder can skip
    /// its own products and avoid an OCR cascade.
    static let outputSuffix = "-ocr"

    private let ingestor = FileIngestor()
    private let preprocessor = Preprocessor()
    private let ocr = OCRService()
    private let composer = PDFComposer()

    // MARK: Pipeline

    /// Ingest a file and run each page through preprocessing + OCR.
    func process(url: URL, settings: Settings) async -> [ProcessedPage] {
        let pages = await ingestor.ingest(url: url, dpi: settings.rasterDPI)
        let name = url.lastPathComponent
        var out: [ProcessedPage] = []
        out.reserveCapacity(pages.count)
        for page in pages {
            out.append(await processPage(page, sourceName: name, settings: settings))
        }
        return out
    }

    /// Run a single in-memory image (e.g. a freshly scanned page) through the pipeline.
    func processImage(_ image: SendableImage, dpi: Double, name: String,
                      settings: Settings) async -> ProcessedPage {
        let page = IngestedPage(image: image, dpi: dpi, existingText: "", hasTextLayer: false)
        return await processPage(page, sourceName: name, settings: settings)
    }

    private func processPage(_ page: IngestedPage, sourceName: String,
                             settings: Settings) async -> ProcessedPage {
        let prepared = await preprocessor.process(image: page.image,
                                                  options: settings.preprocessOptions)
        let result: OCRPageResult
        if shouldOCR(page, policy: settings.textLayerPolicy) {
            result = (try? await ocr.recognize(image: prepared, options: settings.ocrOptions))
                ?? emptyResult(for: prepared)
        } else {
            result = resultFromExistingText(page.existingText, image: prepared)
        }
        return ProcessedPage(image: prepared, original: page.image,
                             dpi: page.dpi, ocr: result, sourceName: sourceName)
    }

    private func shouldOCR(_ page: IngestedPage, policy: TextLayerPolicy) -> Bool {
        guard page.hasTextLayer else { return true }   // image-only page → always OCR
        switch policy {
        case .forceOCR:   return true
        case .skip:       return false
        case .ocrIfSparse: return page.existingText.count < 24
        }
    }

    private func emptyResult(for image: SendableImage) -> OCRPageResult {
        OCRPageResult(lines: [], barcodes: [], imageWidth: image.width, imageHeight: image.height)
    }

    private func resultFromExistingText(_ text: String, image: SendableImage) -> OCRPageResult {
        // No geometry available for a pre-existing text layer; carry the text so
        // text/MD/JSON exports still work (boxes are zero → skipped in the PDF layer).
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            OCRLine(text: String($0), box: .zero, confidence: 1.0, words: [])
        }
        return OCRPageResult(lines: lines, barcodes: [],
                             imageWidth: image.width, imageHeight: image.height)
    }

    // MARK: Export helpers

    func writeSearchablePDF(_ pages: [ProcessedPage], to url: URL) async throws {
        let composable = pages.map {
            ComposablePage(image: $0.image, ocr: $0.ocr, dpi: $0.dpi)
        }
        try await composer.makeSearchablePDF(pages: composable, to: url)
    }

    /// Watch-folder entry point: process a dropped file and write a searchable PDF
    /// plus a sidecar .txt next to it (or into `outputDir`). Returns the PDF URL.
    @discardableResult
    func autoProcess(url: URL, settings: Settings) async throws -> URL {
        let pages = await process(url: url, settings: settings)
        let dir = settings.outputDirectory ?? url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + Self.outputSuffix
        let pdfURL = dir.appendingPathComponent("\(base).pdf")
        try await writeSearchablePDF(pages, to: pdfURL)

        let txt = Exporters.plainText(pages.map(\.ocr))
        try? txt.write(to: dir.appendingPathComponent("\(base).txt"),
                       atomically: true, encoding: .utf8)
        return pdfURL
    }
}
