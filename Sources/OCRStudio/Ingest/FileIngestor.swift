import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// One page produced from a source file, ready for the OCR pipeline.
struct IngestedPage: Sendable {
    var image: SendableImage
    var dpi: Double
    var existingText: String      // text already present in the source (PDF text layer)
    var existingLines: [OCRLine]   // existing PDF text with geometry, when extractable
    var hasTextLayer: Bool
}

/// Loads existing files into page images: rasterizes PDF pages at a target DPI
/// (via PDFKit) and decodes still images (via ImageIO). Also reports any text
/// layer already present in a PDF so callers can decide whether to re-OCR.
actor FileIngestor {

    /// File types this ingestor understands.
    static let supportedExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "bmp", "gif"
    ]

    /// Compatibility helper for small callers. Production processing reads one
    /// page at a time through a reader and reports individual failures.
    func ingest(url: URL, dpi: Double) async throws -> [IngestedPage] {
        let reader = try IngestReader(url: url, dpi: dpi)
        var pages: [IngestedPage] = []
        var remaining = RasterBudget.maximumBytes
        for index in 0..<reader.pageCount {
            let page = try await reader.readPage(at: index, maximumBytes: remaining)
            remaining -= page.image.cgImage.bytesPerRow * page.image.height * 2
            pages.append(page)
        }
        guard !pages.isEmpty else { throw PipelineError.noPages(url) }
        return pages
    }
}

/// Owns one source document and decodes only the requested page. No producer
/// task or unbounded async-stream buffer can run ahead of the OCR consumer.
actor IngestReader {
    private let url: URL
    private let dpi: Double
    private let pdf: PDFDocument?
    private let images: CGImageSource?
    let pageCount: Int
    private static let minimumDPI = 36.0
    private static let maximumDPI = 1_200.0
    private static let maximumDimension = 30_000.0
    private static let maximumPixels = 150_000_000.0

    init(url: URL, dpi: Double) throws {
        try Task.checkCancellation()
        self.url = url
        self.dpi = dpi
        let ext = url.pathExtension.lowercased()
        guard FileIngestor.supportedExtensions.contains(ext) else {
            throw PipelineError.unsupportedFile(url)
        }
        if ext == "pdf" {
            guard dpi.isFinite, (Self.minimumDPI...Self.maximumDPI).contains(dpi) else {
                throw PipelineError.invalidDPI(dpi)
            }
            guard let doc = PDFDocument(url: url) else { throw PipelineError.unreadableFile(url) }
            guard !doc.isLocked else { throw PipelineError.lockedFile(url) }
            pdf = doc
            images = nil
            pageCount = doc.pageCount
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw PipelineError.unreadableFile(url)
            }
            pdf = nil
            images = source
            let count = CGImageSourceGetCount(source)
            pageCount = (ext == "tif" || ext == "tiff") ? count : min(count, 1)
        }
        guard pageCount > 0 else { throw PipelineError.noPages(url) }
    }

    func readPage(at index: Int, maximumBytes: Int = RasterBudget.maximumBytes) throws -> IngestedPage {
        try Task.checkCancellation()
        guard (0..<pageCount).contains(index) else {
            throw PipelineError.unreadablePage(url, page: index + 1)
        }
        let page: IngestedPage
        if let pdf {
            page = try ingestPDF(doc: pdf, index: index, maximumBytes: maximumBytes)
        } else if let images {
            page = try ingestImage(src: images, index: index, maximumBytes: maximumBytes)
        } else { throw PipelineError.unreadableFile(url) }
        try Task.checkCancellation()
        return page
    }

    private func checkBudget(width: Double, height: Double, maximumBytes: Int) throws {
        guard width * height * 8 <= Double(maximumBytes) else {
            throw PipelineError.memoryLimit(url)
        }
    }

    private func ingestImage(src: CGImageSource, index: Int, maximumBytes: Int) throws -> IngestedPage {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
        let pixelWidth = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxPixelSize = max(pixelWidth, pixelHeight)
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw PipelineError.unreadablePage(url, page: index + 1)
        }

        // Apply the same ceilings the PDF path uses. Decoding at native
        // resolution makes an unbounded allocation from untrusted input — a
        // 1200-dpi legal-size TIFF is ~660 MB before preprocessing copies it.
        var targetMaxPixelSize = min(maxPixelSize, Int(Self.maximumDimension))
        let sourcePixels = Double(pixelWidth) * Double(pixelHeight)
        if sourcePixels > Self.maximumPixels {
            let factor = (Self.maximumPixels / sourcePixels).squareRoot()
            targetMaxPixelSize = max(1, Int(Double(targetMaxPixelSize) * factor))
        }

        let decodedScaleEstimate = Double(targetMaxPixelSize) / Double(maxPixelSize)
        try checkBudget(width: ceil(Double(pixelWidth) * decodedScaleEstimate),
                        height: ceil(Double(pixelHeight) * decodedScaleEstimate),
                        maximumBytes: maximumBytes)

        // Decode at (or below) the source resolution, applying EXIF/TIFF orientation.
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary)
        else { throw PipelineError.unreadablePage(url, page: index + 1) }

        // Use the image's real DPI (scanners write it) so the PDF is sized
        // correctly; fall back to 72 if absent or malformed.
        let horizontalDPI = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        let verticalDPI = (props?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
        let candidates = [horizontalDPI, verticalDPI].compactMap { $0 }
            .filter { $0.isFinite && $0 > 0 }
        let nominalDPI = candidates.isEmpty
            ? 72.0
            : candidates.reduce(0, +) / Double(candidates.count)

        // If the decode was capped above, the pixels no longer represent the
        // source DPI — scale it or the composed PDF comes out physically wrong.
        let decodedScale = Double(max(cg.width, cg.height)) / Double(maxPixelSize)
        let imageDPI = nominalDPI * (decodedScale.isFinite && decodedScale > 0
                                     ? decodedScale : 1.0)

        return IngestedPage(image: SendableImage(cgImage: cg), dpi: imageDPI,
                            existingText: "", existingLines: [], hasTextLayer: false)
    }

    private func ingestPDF(doc: PDFDocument, index: Int, maximumBytes: Int) throws -> IngestedPage {
        let scale = CGFloat(dpi) / 72.0
        guard let page = doc.page(at: index) else {
            throw PipelineError.unreadablePage(url, page: index + 1)
        }
        let bounds = page.bounds(for: .mediaBox)
        let rawWidth = bounds.width * scale
        let rawHeight = bounds.height * scale
        guard rawWidth.isFinite, rawHeight.isFinite,
              rawWidth > 0, rawHeight > 0,
              rawWidth <= Self.maximumDimension, rawHeight <= Self.maximumDimension,
              rawWidth * rawHeight <= Self.maximumPixels else {
            throw PipelineError.oversizedPage(url, page: index + 1)
        }
        try checkBudget(width: ceil(rawWidth), height: ceil(rawHeight), maximumBytes: maximumBytes)
        let pixelWidth = Int(rawWidth.rounded())
        let pixelHeight = Int(rawHeight.rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PipelineError.unreadablePage(url, page: index + 1) }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)

        guard let cg = ctx.makeImage() else {
            throw PipelineError.unreadablePage(url, page: index + 1)
        }
        let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = existingTextLines(on: page, pageBounds: bounds, scale: scale)
        return IngestedPage(image: SendableImage(cgImage: cg), dpi: dpi,
                            existingText: text, existingLines: lines,
                            hasTextLayer: !text.isEmpty)
    }

    /// Convert PDFKit's selectable line geometry (PDF points, bottom-left) into the
    /// same image-pixel/top-left coordinate space used by Vision results.
    private func existingTextLines(on page: PDFPage,
                                   pageBounds: CGRect,
                                   scale: CGFloat) -> [OCRLine] {
        guard let pageText = page.string, !pageText.isEmpty,
              let selection = page.selection(
                for: NSRange(location: 0, length: (pageText as NSString).length)
              ) else { return [] }

        return selection.selectionsByLine().compactMap { lineSelection in
            guard let text = lineSelection.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let pdfBox = lineSelection.bounds(for: page).intersection(pageBounds)
            guard !pdfBox.isNull, pdfBox.width > 0, pdfBox.height > 0 else { return nil }
            let pixelBox = CGRect(
                x: (pdfBox.minX - pageBounds.minX) * scale,
                y: (pageBounds.maxY - pdfBox.maxY) * scale,
                width: pdfBox.width * scale,
                height: pdfBox.height * scale
            )
            return OCRLine(text: text, box: pixelBox, confidence: 1.0, words: [])
        }
    }
}
