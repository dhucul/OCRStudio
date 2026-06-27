import AppKit
import CoreText
import CoreGraphics
import Foundation

/// Exporters for the (user-editable) recognized text: a real Word .docx and a
/// clean paginated text PDF. These use the edited text, not the scanned image.
enum RichTextExport {

    private static var bodyAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        return [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: p]
    }

    private static var headingAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.paragraphSpacing = 8
        return [.font: NSFont.boldSystemFont(ofSize: 18), .paragraphStyle: p]
    }

    /// A line counts as a title if it's short and doesn't read like a sentence,
    /// so a document that opens with a paragraph isn't mistakenly promoted.
    private static func looksLikeTitle(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 60 else { return false }
        if let last = t.last, ".,:;".contains(last) { return false }
        return true
    }

    /// Build an attributed document from per-page text, styling each page's first
    /// non-empty line as a heading when it looks like a title.
    static func attributed(from pages: [String]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, page) in pages.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes)) }
            append(page: page, to: result)
        }
        return result
    }

    private static func append(page text: String, to result: NSMutableAttributedString) {
        let lines = text.components(separatedBy: "\n")
        let titleIndex = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let promoteTitle = titleIndex.map { looksLikeTitle(lines[$0]) } ?? false

        for (idx, line) in lines.enumerated() {
            let suffix = idx == lines.count - 1 ? "" : "\n"
            let attrs = (idx == titleIndex && promoteTitle) ? headingAttributes : bodyAttributes
            result.append(NSAttributedString(string: line + suffix, attributes: attrs))
        }
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
