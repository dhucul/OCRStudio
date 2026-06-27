import CoreGraphics
import Foundation

/// A single recognized word with its location in **image pixel coordinates**
/// (origin top-left), matching how the rest of the app and the JSON export
/// describe geometry.
struct OCRWord: Codable, Hashable, Sendable {
    var text: String
    var box: CGRect
    var confidence: Double
}

/// A recognized line of text (Vision's natural recognition unit).
struct OCRLine: Codable, Hashable, Sendable {
    var text: String
    var box: CGRect
    var confidence: Double
    var words: [OCRWord]
}

/// A detected 1D/2D barcode (QR, Code128, EAN, PDF417, …).
struct DetectedBarcode: Codable, Hashable, Sendable {
    var payload: String
    var symbology: String
    var box: CGRect
}

/// The full OCR result for one page.
struct OCRPageResult: Codable, Hashable, Sendable {
    var lines: [OCRLine]
    var barcodes: [DetectedBarcode]
    var imageWidth: Int
    var imageHeight: Int

    /// All recognized text joined line-by-line (reading order as returned by Vision).
    var fullText: String { lines.map(\.text).joined(separator: "\n") }

    /// Average per-line confidence, 0…1 (nil when there is no text).
    var averageConfidence: Double? {
        guard !lines.isEmpty else { return nil }
        return lines.map(\.confidence).reduce(0, +) / Double(lines.count)
    }
}
