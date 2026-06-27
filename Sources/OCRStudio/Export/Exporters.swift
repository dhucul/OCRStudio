import Foundation

/// Plain-text, Markdown and JSON exporters for OCR results.
enum Exporters {

    /// Plain text, pages separated by a form-feed (matches common OCR tooling).
    static func plainText(_ pages: [OCRPageResult]) -> String {
        pages.map(\.fullText).joined(separator: "\n\n\u{000C}\n")
    }

    /// Lightweight Markdown: one section per page, recognized lines as paragraphs,
    /// plus any detected barcodes.
    static func markdown(_ pages: [OCRPageResult]) -> String {
        var out = ""
        for (i, page) in pages.enumerated() {
            out += "## Page \(i + 1)\n\n"
            if page.lines.isEmpty {
                out += "_No text recognized._\n\n"
            } else {
                out += page.fullText + "\n\n"
            }
            if !page.barcodes.isEmpty {
                out += "**Barcodes:**\n\n"
                for code in page.barcodes {
                    out += "- `\(code.symbology)`: \(code.payload)\n"
                }
                out += "\n"
            }
        }
        return out
    }

    /// Structured JSON with per-line/per-word boxes and confidence.
    static func json(_ pages: [OCRPageResult]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(pages)
    }
}
