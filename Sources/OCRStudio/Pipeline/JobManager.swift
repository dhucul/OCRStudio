import Foundation
import CoreGraphics
import CryptoKit

enum PipelineError: LocalizedError, Sendable {
    case unsupportedFile(URL)
    case unreadableFile(URL)
    case lockedFile(URL)
    case unreadablePage(URL, page: Int)
    case noPages(URL)
    case invalidDPI(Double)
    case oversizedPage(URL, page: Int)
    case memoryLimit(URL)
    case incompleteDocument([String])
    case sourceChanged(URL)

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
        case .memoryLimit(let url):
            return "Raster memory limit reached for \(url.lastPathComponent). Use a lower DPI or split the batch."
        case .incompleteDocument(let failures):
            return "Incomplete document: " + failures.joined(separator: "; ")
        case .sourceChanged(let url):
            return "\(url.lastPathComponent) changed during processing; waiting for a stable version."
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
    var cropToContent: Bool = false
    var isScanned: Bool = false

    var retainedBytes: Int {
        image.cgImage.bytesPerRow * image.height + original.cgImage.bytesPerRow * original.height
    }
}

/// Orchestrates the ingest → preprocess → OCR pipeline. Shared by the interactive
/// "open files" path, batch processing, and the watch folder.
struct ProcessingReport: Sendable {
    var pages: [ProcessedPage] = []
    var failures: [String] = []
}

actor JobManager {

    /// Suffix added to auto-generated outputs. Shared so the watch folder can skip
    /// its own products and avoid an OCR cascade.
    static let outputSuffix = "-ocr"

    private let preprocessor = Preprocessor()
    private let ocr = OCRService()
    private let composer = PDFComposer()

    // MARK: Pipeline

    /// Ingest a file and run each page through preprocessing + OCR.
    /// `cropToContent` trims empty margins (used for full-bed scans).
    func process(url: URL, settings: Settings,
                 cropToContent: Bool = false) async throws -> [ProcessedPage] {
        let report = try await processReport(url: url, settings: settings, cropToContent: cropToContent)
        guard report.failures.isEmpty else { throw PipelineError.incompleteDocument(report.failures) }
        return report.pages
    }

    func processReport(url: URL, settings: Settings, cropToContent: Bool = false,
                       isScanned: Bool = false,
                       maximumRetainedBytes: Int = RasterBudget.maximumBytes) async throws -> ProcessingReport {
        try Task.checkCancellation()
        let reader = try IngestReader(url: url, dpi: settings.rasterDPI)
        var report = ProcessingReport()
        var remaining = max(0, maximumRetainedBytes)
        for index in 0..<reader.pageCount {
            try Task.checkCancellation()
            do {
                let page = try await reader.readPage(at: index, maximumBytes: remaining)
                var processed = try await processPage(page, sourceName: url.lastPathComponent,
                                                      settings: settings, cropToContent: cropToContent)
                processed.isScanned = isScanned
                guard processed.retainedBytes <= remaining else { throw PipelineError.memoryLimit(url) }
                remaining -= processed.retainedBytes
                report.pages.append(processed)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failures.append("Page \(index + 1): \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        return report
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
        try Task.checkCancellation()
        let prepared = try await preprocessor.process(image: page.image,
                                                  options: settings.preprocessOptions)
        var result: OCRPageResult
        // Geometric preprocessing invalidates the source PDF's text boxes.
        if settings.autoCropDeskew || shouldOCR(page, policy: settings.textLayerPolicy) {
            result = try await ocr.recognize(image: prepared, options: settings.ocrOptions)
        } else {
            result = resultFromExistingText(page.existingLines, image: prepared)
            if settings.detectBarcodes {
                result.barcodes = try await ocr.detectBarcodes(image: prepared)
            }
        }

        var outImage = prepared
        if cropToContent {
            (outImage, result) = contentCropped(image: prepared, result: result)
        }
        try Task.checkCancellation()
        return ProcessedPage(image: outImage, original: page.image,
                             dpi: page.dpi, ocr: result, sourceName: sourceName,
                             cropToContent: cropToContent)
    }

    /// Crop only empty near-white margins. Visual ink (including photographs,
    /// signatures and faint marks) and every recognized box constrain the crop.
    func contentCropped(image: SendableImage,
                        result: OCRPageResult) -> (SendableImage, OCRPageResult) {
        let textBoxes = result.lines.flatMap { [$0.box] + $0.words.map(\.box) }
        let boxes = (textBoxes + result.barcodes.map(\.box))
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard let ink = Self.visualContentBounds(image.cgImage) else { return (image, result) }
        let first = ink
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let union = boxes.reduce(first) { $0.union($1) }
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

    private static func visualContentBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h {
            for x in 0..<w {
                let offset = y * ctx.bytesPerRow + x * 4
                if min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) < 254 {
                    x0 = min(x0, x); y0 = min(y0, y)
                    x1 = max(x1, x); y1 = max(y1, y)
                }
            }
        }
        guard x1 >= x0, y1 >= y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
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

    private struct PendingSidecar {
        let version: FileVersion
        let text: Data
        let pdfVersion: FileVersion
    }
    private var pendingSidecars: [URL: PendingSidecar] = [:]

    /// Include the extension and a stable source-path digest, so distinct inputs
    /// (including inputs in different folders) never share an output name.
    static func outputURL(for source: URL, directory: URL) -> URL {
        let path = source.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = String(source.lastPathComponent.prefix(40))
        return directory.appendingPathComponent("\(name)-\(digest)\(outputSuffix).pdf")
    }

    @discardableResult
    func autoProcess(url: URL, settings: Settings) async throws -> URL {
        try Task.checkCancellation()
        let version = try FileVersion.read(url)
        let dir = settings.outputDirectory ?? url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdfURL = Self.outputURL(for: url, directory: dir)
        let textURL = pdfURL.deletingPathExtension().appendingPathExtension("txt")
        if let pending = pendingSidecars[pdfURL], pending.version == version,
           (try? FileVersion.read(pdfURL)) == pending.pdfVersion {
            try AtomicFile.write(pending.text, to: textURL)
            pendingSidecars[pdfURL] = nil
            return pdfURL
        }
        pendingSidecars[pdfURL] = nil

        // Process an immutable copy. A fresh metadata check before publishing
        // prevents acknowledgment/output of a version superseded during OCR.
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        let stagedPDF = dir.appendingPathComponent(".ocrstudio-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: snapshot)
            try? FileManager.default.removeItem(at: stagedPDF)
        }
        try FileManager.default.copyItem(at: url, to: snapshot)
        guard try FileVersion.read(url) == version else { throw PipelineError.sourceChanged(url) }
        let pages = try await process(url: snapshot, settings: settings)
        try await writeSearchablePDF(pages, to: stagedPDF)
        guard try FileVersion.read(url) == version else { throw PipelineError.sourceChanged(url) }
        try AtomicFile.write(to: pdfURL) { try FileManager.default.copyItem(at: stagedPDF, to: $0) }

        let text = Data(Exporters.plainText(pages.map(\.ocr)).utf8)
        pendingSidecars[pdfURL] = PendingSidecar(version: version, text: text,
                                               pdfVersion: try FileVersion.read(pdfURL))
        // Failure remains visible and retryable without rerunning OCR.
        try AtomicFile.write(text, to: textURL)
        pendingSidecars[pdfURL] = nil
        return pdfURL
    }
}
