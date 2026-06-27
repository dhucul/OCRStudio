import CoreImage
import Vision
import CoreGraphics

struct ImagePreprocessOptions: Sendable {
    var autoCropDeskew: Bool = false
    var enhanceContrast: Bool = true
    var denoise: Bool = true
    var grayscale: Bool = false

    var isNoOp: Bool { !autoCropDeskew && !enhanceContrast && !denoise && !grayscale }
}

/// Image cleanup to improve OCR accuracy: optional document auto-crop/deskew
/// (Vision document segmentation + Core Image perspective correction), contrast
/// enhancement, denoise, and grayscale conversion.
actor Preprocessor {

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func process(image: SendableImage, options: ImagePreprocessOptions) -> SendableImage {
        guard !options.isNoOp else { return image }

        var ci = CIImage(cgImage: image.cgImage)

        if options.autoCropDeskew, let corrected = perspectiveCorrected(ci) {
            ci = corrected
        }
        if options.grayscale {
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        }
        if options.enhanceContrast {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.08,
                kCIInputBrightnessKey: 0.0,
                kCIInputSaturationKey: options.grayscale ? 0.0 : 1.0
            ])
        }
        if options.denoise {
            ci = ci.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.02,
                "inputSharpness": 0.40
            ])
        }

        let rect = ci.extent
        guard !rect.isInfinite, !rect.isEmpty,
              let out = context.createCGImage(ci, from: rect) else {
            return image
        }
        return SendableImage(cgImage: out)
    }

    /// Detect the document's quad and perspective-correct (crops + deskews).
    private func perspectiveCorrected(_ ci: CIImage) -> CIImage? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        try? handler.perform([request])
        guard let obs = request.results?.first else { return nil }

        let w = ci.extent.width
        let h = ci.extent.height
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }

        return ci.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(obs.topLeft),
            "inputTopRight": point(obs.topRight),
            "inputBottomLeft": point(obs.bottomLeft),
            "inputBottomRight": point(obs.bottomRight)
        ])
    }
}
