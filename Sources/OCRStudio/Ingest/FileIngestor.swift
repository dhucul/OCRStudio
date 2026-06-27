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

    func ingest(url: URL, dpi: Double) -> [IngestedPage] {
        if url.pathExtension.lowercased() == "pdf" {
            return ingestPDF(url: url, dpi: dpi)
        }
        if let page = ingestImage(url: url) {
            return [page]
        }
        return []
    }

    private func ingestImage(url: URL) -> IngestedPage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return IngestedPage(image: SendableImage(cgImage: cg), dpi: 72,
                            existingText: "", hasTextLayer: false)
    }

    private func ingestPDF(url: URL, dpi: Double) -> [IngestedPage] {
        guard let doc = PDFDocument(url: url) else { return [] }
        let scale = CGFloat(dpi) / 72.0
        var pages: [IngestedPage] = []

        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let pxW = Int((bounds.width * scale).rounded())
            let pxH = Int((bounds.height * scale).rounded())
            guard pxW > 0, pxH > 0,
                  let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }

            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            page.draw(with: .mediaBox, to: ctx)

            guard let cg = ctx.makeImage() else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            pages.append(IngestedPage(image: SendableImage(cgImage: cg),
                                      dpi: dpi,
                                      existingText: text,
                                      hasTextLayer: !text.isEmpty))
        }
        return pages
    }
}
