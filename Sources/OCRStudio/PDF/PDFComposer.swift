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
        try AtomicFile.write(to: url) { temporary in
            try Self.render(pages: pages, to: temporary)
        }
    }

    private static func render(pages: [ComposablePage], to url: URL) throws {
        try Task.checkCancellation()
        guard !pages.isEmpty else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Cannot create a PDF with no pages."
            ])
        }
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var closed = false
        defer { if !closed { ctx.closePDF() } }
        for page in pages {
            try Task.checkCancellation()
            // `max(x, 1)` does NOT screen out NaN — every NaN comparison is false,
            // so max() returns the NaN and it propagates into the media box.
            let dpi = page.dpi.isFinite && page.dpi > 0 ? page.dpi : 72.0
            let scale = CGFloat(72.0 / dpi)
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
        closed = true
        try Self.verifyWritten(url, expectedPages: pages.count)
    }

    /// Validate the complete temporary PDF, not a preexisting destination or a
    /// nonempty prefix left by a failed writer.
    static func verifyWritten(_ url: URL, expectedPages: Int? = nil) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 1_024 ? size - 1_024 : 0)
        let tail = try handle.readToEnd() ?? Data()
        guard tail.range(of: Data("%%EOF".utf8)) != nil,
              let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0,
              expectedPages == nil || document.numberOfPages == expectedPages,
              (1...document.numberOfPages).allSatisfy({ document.page(at: $0) != nil }) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "The completed PDF could not be validated at \(url.path)."
            ])
        }
    }

    /// Draw one invisible word, scaled horizontally so its glyph advance matches
    /// the OCR box width (keeps selection highlights aligned to the visible text).
    private static func drawInvisibleText(_ text: String,
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
