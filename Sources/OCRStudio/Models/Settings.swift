import Foundation

/// How to treat PDFs that already contain a selectable text layer.
enum TextLayerPolicy: String, Codable, CaseIterable, Sendable {
    case skip            // keep existing text, don't OCR
    case forceOCR        // always OCR (rasterize + re-recognize)
    case ocrIfSparse     // OCR only when the existing text looks too short to be real

    var label: String {
        switch self {
        case .skip: return "Skip pages that already have text"
        case .forceOCR: return "Always re-OCR every page"
        case .ocrIfSparse: return "OCR only if existing text is sparse"
        }
    }
}

/// User-facing configuration, persisted via `UserDefaults`.
struct Settings: Codable, Sendable {
    // OCR
    var recognitionLanguages: [String] = ["en-US"]
    var automaticLanguageDetection: Bool = true
    var detectBarcodes: Bool = true

    // Preprocessing
    var autoCropDeskew: Bool = false       // off by default: only helps photographed docs
    var enhanceContrast: Bool = true
    var denoise: Bool = true
    var grayscale: Bool = false

    // Scanned-page handling
    var autoCropScannedPages: Bool = true  // trim empty scanner-bed margins, centering content

    // Ingest / rasterization
    var rasterDPI: Double = 200
    var textLayerPolicy: TextLayerPolicy = .ocrIfSparse

    // Output
    var outputDirectory: URL?
    var watchFolder: URL?

    var preprocessOptions: ImagePreprocessOptions {
        ImagePreprocessOptions(autoCropDeskew: autoCropDeskew,
                               enhanceContrast: enhanceContrast,
                               denoise: denoise,
                               grayscale: grayscale)
    }

    var ocrOptions: OCROptions {
        OCROptions(languages: recognitionLanguages,
                   automaticLanguageDetection: automaticLanguageDetection,
                   detectBarcodes: detectBarcodes)
    }

    // MARK: Persistence

    private static let key = "OCRStudio.Settings"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
