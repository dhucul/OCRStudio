import Vision
import CoreGraphics
import ImageIO
import Foundation

struct OCROptions: Sendable {
    var languages: [String] = ["en-US"]
    var automaticLanguageDetection: Bool = true
    var detectBarcodes: Bool = true
}

/// On-device OCR via Apple's Vision framework.
///
/// Runs off the main actor. Vision's `VNObservation` results are reference types
/// and not `Sendable`, so we translate them into our own value models **inside**
/// the actor before returning.
actor OCRService {

    func recognize(image: SendableImage,
                   orientation: CGImagePropertyOrientation = .up,
                   options: OCROptions = OCROptions()) throws -> OCRPageResult {

        let cg = image.cgImage
        let width = cg.width
        let height = cg.height

        // --- Text recognition ---
        let textRequest = VNRecognizeTextRequest()
        // Revision FIRST: it re-validates the revision-scoped language properties,
        // so anything configured before it can be silently discarded.
        if let newest = VNRecognizeTextRequest.supportedRevisions.max() {
            textRequest.revision = newest
        }
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = options.automaticLanguageDetection
        if !options.languages.isEmpty {
            textRequest.recognitionLanguages = options.languages
        }

        let barcodeRequest = VNDetectBarcodesRequest()

        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        // Perform separately: barcodes are the optional extra, and bundling them
        // means one barcode failure throws away text that recognized fine.
        try handler.perform([textRequest])
        if options.detectBarcodes {
            try? handler.perform([barcodeRequest])
        }

        // --- Lines + per-word boxes ---
        var lines: [OCRLine] = []
        for obs in (textRequest.results ?? []) {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let string = candidate.string
            let lineBox = Geometry.pixelRectTopLeft(fromNormalized: obs.boundingBox,
                                                    width: width, height: height)
            let confidence = Double(candidate.confidence)

            var words: [OCRWord] = []
            string.enumerateSubstrings(in: string.startIndex..<string.endIndex,
                                       options: .byWords) { sub, range, _, _ in
                guard let sub, !sub.isEmpty else { return }
                if let rectObs = try? candidate.boundingBox(for: range) {
                    let box = Geometry.pixelRectTopLeft(fromNormalized: rectObs.boundingBox,
                                                        width: width, height: height)
                    words.append(OCRWord(text: sub, box: box, confidence: confidence))
                }
            }

            lines.append(OCRLine(text: string, box: lineBox,
                                 confidence: confidence, words: words))
        }

        // --- Barcodes ---
        var barcodes: [DetectedBarcode] = []
        if options.detectBarcodes {
            for b in (barcodeRequest.results ?? []) {
                let box = Geometry.pixelRectTopLeft(fromNormalized: b.boundingBox,
                                                    width: width, height: height)
                barcodes.append(DetectedBarcode(payload: b.payloadStringValue ?? "",
                                                symbology: b.symbology.rawValue,
                                                box: box))
            }
        }

        return OCRPageResult(lines: lines, barcodes: barcodes,
                             imageWidth: width, imageHeight: height)
    }
}
