import Foundation
import CoreGraphics

enum PipelineError: LocalizedError, Sendable {
    case unsupportedFile(URL)
    case unreadableFile(URL)
    case lockedFile(URL)
    case unreadablePage(URL, page: Int)
    case noPages(URL)
    case invalidDPI(Double)
    case oversizedPage(URL, page: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url):
            return "Unsupported file type: \(url.lastPathComponent)"
        case .unreadableFile(let url):
            return "Could not read \(url.lastPathComponent)."
        case .lockedFile(let url):
            return "\(url.lastPathComponent) is password-protected."
        case .unreadablePage(let url, let page):
            return "Could not render page \(page) of \(url.lastPathComponent)."
        case .noPages(let url):
            return "No readable pages were found in \(url.lastPathComponent)."
        case .invalidDPI(let dpi):
            return "Invalid PDF rasterization resolution: \(dpi)."
        case .oversizedPage(let url, let page):
            return "Page \(page) of \(url.lastPathComponent) is too large to rasterize safely."
        }
    }
}

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
    var cropToContent: Bool = false   // whether this page should be content-cropped (scanned pages)
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
    /// `cropToContent` trims empty margins (used for full-bed scans).
    func process(url: URL, settings: Settings,
                 cropToContent: Bool = false) async throws -> [ProcessedPage] {
        let pages = try await ingestor.ingest(url: url, dpi: settings.rasterDPI)
        let name = url.lastPathComponent
        var out: [ProcessedPage] = []
        out.reserveCapacity(pages.count)
        for page in pages {
            out.append(try await processPage(page, sourceName: name, settings: settings,
                                             cropToContent: cropToContent))
        }
        guard !out.isEmpty else { throw PipelineError.noPages(url) }
        return out
    }

    /// Run a single in-memory image (e.g. a freshly scanned page) through the pipeline.
    func processImage(_ image: SendableImage, dpi: Double, name: String,
                      settings: Settings,
                      cropToContent: Bool = false) async throws -> ProcessedPage {
        let page = IngestedPage(image: image, dpi: dpi, existingText: "",
                                existingLines: [], hasTextLayer: false)
        return try await processPage(page, sourceName: name, settings: settings,
                                     cropToContent: cropToContent)
    }

    private func processPage(_ page: IngestedPage, sourceName: String,
                             settings: Settings,
                             cropToContent: Bool) async throws -> ProcessedPage {
        let prepared = await preprocessor.process(image: page.image,
                                                  options: settings.preprocessOptions)
        var result: OCRPageResult
        if shouldOCR(page, policy: settings.textLayerPolicy) {
            result = try await ocr.recognize(image: prepared, options: settings.ocrOptions)
        } else {
            result = resultFromExistingText(page.existingLines, image: prepared)
        }

        var outImage = prepared
        if cropToContent {
            (outImage, result) = contentCropped(image: prepared, result: result)
        }
        return ProcessedPage(image: outImage, original: page.image,
                             dpi: page.dpi, ocr: result, sourceName: sourceName,
                             cropToContent: cropToContent)
    }

    /// Trim a full-bed scan down to its content (the OCR text/barcode extent, plus a
    /// margin) and shift the boxes to match, so the page is tight and centered.
    /// No-ops when there's no text or the content already (nearly) fills the page.
    private func contentCropped(image: SendableImage,
                                result: OCRPageResult) -> (SendableImage, OCRPageResult) {
        // Only confident text drives the crop bounds, so a stray low-confidence
        // speck (edge mark, hole punch) can't blow up or de-center the crop. All
        // recognized text is still kept in the result.
        let textBoxes = result.lines
            .filter { $0.confidence >= 0.3 && $0.box.width > 0 && $0.box.height > 0 }
            .map(\.box)
        // Barcodes need the same degenerate-rect filter: Vision emits zero-size
        // boxes for partial reads, and one of those drags the union to the origin
        // and silently de-centers the crop.
        let barcodeBoxes = result.barcodes.map(\.box)
            .filter { $0.width > 0 && $0.height > 0 }
        let boxes = textBoxes + barcodeBoxes
        guard let first = boxes.first else { return (image, result) }

        let w = CGFloat(image.width), h = CGFloat(image.height)
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        let crop = union
            .insetBy(dx: -w * 0.05, dy: -h * 0.05)   // even margin around the content
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            .integral
        guard crop.width > 0, crop.height > 0,
              crop.width * crop.height < 0.95 * w * h,   // skip if barely cropping
              let cropped = image.cgImage.cropping(to: crop) else {
            return (image, result)
        }

        let dx = crop.minX, dy = crop.minY
        func shift(_ r: CGRect) -> CGRect { r.offsetBy(dx: -dx, dy: -dy) }
        let lines = result.lines.map { line in
            OCRLine(text: line.text, box: shift(line.box), confidence: line.confidence,
                    words: line.words.map {
                        OCRWord(text: $0.text, box: shift($0.box), confidence: $0.confidence)
                    })
        }
        let barcodes = result.barcodes.map {
            DetectedBarcode(payload: $0.payload, symbology: $0.symbology, box: shift($0.box))
        }
        let adjusted = OCRPageResult(lines: lines, barcodes: barcodes,
                                     imageWidth: cropped.width, imageHeight: cropped.height)
        return (SendableImage(cgImage: cropped), adjusted)
    }

    /// A page is blank when OCR found no text or barcodes AND it has almost no ink
    /// (so a text page or a figure-only page is never mistaken for blank).
    func isBlankPage(_ page: ProcessedPage) -> Bool {
        let hasText = page.ocr.lines.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasText || !page.ocr.barcodes.isEmpty { return false }
        return Self.inkCoverage(page.image.cgImage) < 0.004   // < 0.4% dark pixels
    }

    /// Fraction of dark ("ink") pixels in a downsampled grayscale copy of the image.
    private static func inkCoverage(_ cg: CGImage) -> Double {
        let maxDim = 600
        let scale = min(1.0, Double(maxDim) / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * scale))
        let h = max(1, Int(Double(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 1.0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 1.0 }

        // Read the stride back rather than assuming rows are exactly `w` bytes —
        // CoreGraphics is free to pad them.
        let stride = ctx.bytesPerRow
        guard stride >= w else { return 1.0 }
        let ptr = data.bindMemory(to: UInt8.self, capacity: stride * h)
        var dark = 0
        for y in 0..<h {
            let row = y * stride
            for x in 0..<w where ptr[row + x] < 180 { dark += 1 }
        }
        return Double(dark) / Double(w * h)
    }

    private func shouldOCR(_ page: IngestedPage, policy: TextLayerPolicy) -> Bool {
        guard page.hasTextLayer else { return true }   // image-only page → always OCR
        guard !page.existingLines.isEmpty else { return true } // raster export needs text geometry
        switch policy {
        case .forceOCR:   return true
        case .skip:       return false
        case .ocrIfSparse: return page.existingText.count < 24
        }
    }

    private func resultFromExistingText(_ lines: [OCRLine],
                                        image: SendableImage) -> OCRPageResult {
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
        let pages = try await process(url: url, settings: settings)
        guard !pages.isEmpty else { throw PipelineError.noPages(url) }
        let dir = settings.outputDirectory ?? url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent + Self.outputSuffix
        let pdfURL = dir.appendingPathComponent("\(base).pdf")
        try await writeSearchablePDF(pages, to: pdfURL)

        // Best-effort: a failed sidecar must not invalidate a PDF that is already
        // on disk, or the watch folder re-OCRs the whole file on every retry.
        let txt = Exporters.plainText(pages.map(\.ocr))
        try? txt.write(to: dir.appendingPathComponent("\(base).txt"),
                       atomically: true, encoding: .utf8)
        return pdfURL
    }
}
