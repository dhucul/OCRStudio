import CoreGraphics

/// Single source of truth for coordinate-space conversions.
///
/// Vision returns rectangles **normalized** to `[0,1]` with the origin at the
/// **bottom-left**. The rest of the app stores boxes in **image pixels** with the
/// origin at the **top-left** (natural for UI overlays and JSON). The PDF text
/// layer needs **PDF points** with the origin at the **bottom-left**. Keep every
/// conversion here so the mappings can be reasoned about (and tested) in one place.
enum Geometry {

    /// Vision normalized rect (bottom-left origin) → pixel rect with **top-left** origin.
    static func pixelRectTopLeft(fromNormalized r: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        let x = r.minX * w
        let pxW = r.width * w
        let pxH = r.height * h
        let yTop = (1.0 - r.maxY) * h          // flip Y: normalized bottom-left → pixel top-left
        return CGRect(x: x, y: yTop, width: pxW, height: pxH)
    }

    /// Pixel rect (top-left origin) → PDF point rect (bottom-left origin).
    /// `scale` maps pixels to points (= 72 / dpi).
    static func pdfRect(fromPixelTopLeft r: CGRect, imageHeight: Int, scale: CGFloat) -> CGRect {
        let x = r.minX * scale
        let pdfW = r.width * scale
        let pdfH = r.height * scale
        let y = (CGFloat(imageHeight) - r.maxY) * scale   // flip Y back to bottom-left
        return CGRect(x: x, y: y, width: pdfW, height: pdfH)
    }
}
