import CoreGraphics
import CoreText
import Foundation

/// One page to compose into the searchable PDF.
struct ComposablePage: Sendable {
    var image: SendableImage
    var ocr: OCRPageResult
    var dpi: Double
}

/// Writes a searchable PDF: each page draws the scanned/source raster, then lays
/// an **invisible** text layer over it positioned to match the OCR boxes, so the
/// PDF looks identical to the image but the text is selectable and searchable
/// (the same technique ocrmypdf uses).
actor PDFComposer {

    func makeSearchablePDF(pages: [ComposablePage], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        for page in pages {
            let scale = CGFloat(72.0 / max(page.dpi, 1))
            let pageW = CGFloat(page.image.width) * scale
            let pageH = CGFloat(page.image.height) * scale
            let box = CGRect(x: 0, y: 0, width: pageW, height: pageH)

            // CoreGraphics wants the per-page media box as CFData (raw CGRect),
            // not an NSValue — otherwise the page falls back to the default size.
            let boxData = withUnsafeBytes(of: box) { Data($0) } as CFData
            let pageInfo = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
            ctx.beginPDFPage(pageInfo)

            // 1. visible raster layer (fills the page)
            ctx.draw(page.image.cgImage, in: box)

            // 2. invisible, selectable text layer — one run per line preserves
            //    punctuation and spacing (word enumeration would drop them).
            ctx.setTextDrawingMode(.invisible)
            for line in page.ocr.lines where !line.text.isEmpty {
                drawInvisibleText(line.text,
                                  pixelBox: line.box,
                                  imageHeight: page.image.height,
                                  scale: scale,
                                  in: ctx)
            }

            ctx.endPDFPage()
        }

        ctx.closePDF()
    }

    /// Draw one invisible word, scaled horizontally so its glyph advance matches
    /// the OCR box width (keeps selection highlights aligned to the visible text).
    private func drawInvisibleText(_ text: String,
                                   pixelBox: CGRect,
                                   imageHeight: Int,
                                   scale: CGFloat,
                                   in ctx: CGContext) {
        guard !text.isEmpty, pixelBox.width > 0, pixelBox.height > 0 else { return }

        let pdfBox = Geometry.pdfRect(fromPixelTopLeft: pixelBox,
                                      imageHeight: imageHeight, scale: scale)
        let fontSize = max(pdfBox.height, 1)

        // Font cascade so non-Latin scripts still produce real glyphs (not .notdef).
        let baseFont = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let shaped = CTFontCreateForString(baseFont, text as CFString,
                                           CFRange(location: 0, length: (text as NSString).length))

        let attributed = NSAttributedString(string: text, attributes: [.font: shaped])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let advance = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        let scaleX = advance > 0 ? pdfBox.width / CGFloat(advance) : 1.0

        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: scaleX, y: 1.0)
        ctx.textPosition = CGPoint(x: pdfBox.minX, y: pdfBox.minY)
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }
}
