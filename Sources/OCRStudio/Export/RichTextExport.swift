import AppKit
import CoreText
import CoreGraphics
import Foundation

/// Exporters for the (user-editable) recognized text: a real Word .docx and a
/// clean paginated text PDF. These use the edited text, not the scanned image.
enum RichTextExport {

    /// Build a simple attributed document from per-page text (pages separated by a blank line).
    static func attributed(from pages: [String]) -> NSAttributedString {
        let body = pages.joined(separator: "\n\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .paragraphStyle: paragraph
        ])
    }

    /// Word .docx data via AppKit's Office Open XML writer.
    static func wordData(from pages: [String]) throws -> Data {
        let attr = attributed(from: pages)
        return try attr.data(from: NSRange(location: 0, length: attr.length),
                             documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    /// Render the text into a paginated, selectable PDF (a text document — not the scan).
    static func writeTextPDF(pages: [String], to url: URL) throws {
        let attr = attributed(from: pages)
        let pageW: CGFloat = 612, pageH: CGFloat = 792, margin: CGFloat = 54
        let textRect = CGRect(x: margin, y: margin, width: pageW - 2 * margin, height: pageH - 2 * margin)
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: textRect, transform: nil)
        let total = attr.length
        var start = 0

        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length <= 0 { break }          // nothing fit (or empty) → stop
            start += visible.length
        } while start < total

        ctx.closePDF()
    }
}
