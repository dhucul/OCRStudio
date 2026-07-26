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

    private static let minimumDPI = 36.0
    private static let maximumDPI = 1_200.0
    private static let maximumDimension = 30_000.0
    private static let maximumPixels = 150_000_000.0

    /// File types this ingestor understands.
    static let supportedExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "bmp", "gif"
    ]

    func ingest(url: URL, dpi: Double) throws -> [IngestedPage] {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw PipelineError.unsupportedFile(url)
        }

        let pages: [IngestedPage]
        if ext == "pdf" {
            pages = try ingestPDF(url: url, dpi: dpi)
        } else {
            pages = try ingestImages(url: url, includeAllFrames: ext == "tif" || ext == "tiff")
        }
        guard !pages.isEmpty else { throw PipelineError.noPages(url) }
        return pages
    }

    private func ingestImages(url: URL, includeAllFrames: Bool) throws -> [IngestedPage] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PipelineError.unreadableFile(url)
        }

        let sourceCount = CGImageSourceGetCount(src)
        let count = includeAllFrames ? sourceCount : min(sourceCount, 1)
        var pages: [IngestedPage] = []
        pages.reserveCapacity(count)

        for index in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
            let pixelWidth = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let pixelHeight = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let maxPixelSize = max(pixelWidth, pixelHeight)
            guard maxPixelSize > 0 else { continue }

            // Decode at the source resolution while applying EXIF/TIFF orientation.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary)
            else { continue }

            // Use the image's real DPI (scanners write it) so the PDF is sized
            // correctly; fall back to 72 if absent or malformed.
            let horizontalDPI = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
            let verticalDPI = (props?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
            let candidates = [horizontalDPI, verticalDPI].compactMap { $0 }
                .filter { $0.isFinite && $0 > 0 }
            let imageDPI = candidates.isEmpty
                ? 72.0
                : candidates.reduce(0, +) / Double(candidates.count)

            pages.append(IngestedPage(image: SendableImage(cgImage: cg), dpi: imageDPI,
                                      existingText: "", existingLines: [],
                                      hasTextLayer: false))
        }
        guard !pages.isEmpty else { throw PipelineError.unreadableFile(url) }
        return pages
    }

    private func ingestPDF(url: URL, dpi: Double) throws -> [IngestedPage] {
        guard dpi.isFinite, (Self.minimumDPI...Self.maximumDPI).contains(dpi) else {
            throw PipelineError.invalidDPI(dpi)
        }
        guard let doc = PDFDocument(url: url) else {
            throw PipelineError.unreadableFile(url)
        }
        let scale = CGFloat(dpi) / 72.0
        var pages: [IngestedPage] = []

        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let rawWidth = bounds.width * scale
            let rawHeight = bounds.height * scale
            guard rawWidth.isFinite, rawHeight.isFinite,
                  rawWidth > 0, rawHeight > 0,
                  rawWidth <= Self.maximumDimension, rawHeight <= Self.maximumDimension,
                  rawWidth * rawHeight <= Self.maximumPixels else {
                throw PipelineError.oversizedPage(url, page: index + 1)
            }
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
            pages.append(IngestedPage(image: SendableImage(cgImage: cg),
                                      dpi: dpi,
                                      existingText: text,
                                      existingLines: lines,
                                      hasTextLayer: !text.isEmpty))
        }
        return pages
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
