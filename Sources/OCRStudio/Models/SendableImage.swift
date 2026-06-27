import CoreGraphics

/// An immutable wrapper that lets a `CGImage` cross actor boundaries.
///
/// `CGImage` is reference-typed and not `Sendable`, but the instances we pass
/// around are never mutated after creation, so this wrapper is safe in practice.
struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage

    init(cgImage: CGImage) { self.cgImage = cgImage }

    var width: Int { cgImage.width }
    var height: Int { cgImage.height }
    var pixelSize: CGSize { CGSize(width: width, height: height) }
}
