// Renders the DMG window background (bg.png @1x and bg@2x.png) into a folder.
// Usage: swift scripts/make-dmg-bg.swift <output-dir>
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Foundation

let W: CGFloat = 600, H: CGFloat = 420

func render(_ scale: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale),
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)   // draw in 600x420 design coordinates

    // Soft vertical gradient.
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1),
                                   CGColor(red: 0.87, green: 0.91, blue: 0.98, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

    // Arrow pointing right, at the icon center line (design y = 190).
    let ay = H - 190
    ctx.setStrokeColor(CGColor(red: 0.20, green: 0.48, blue: 0.92, alpha: 1))
    ctx.setLineWidth(7); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 250, y: ay)); ctx.addLine(to: CGPoint(x: 345, y: ay)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 345, y: ay + 13))
    ctx.addLine(to: CGPoint(x: 367, y: ay))
    ctx.addLine(to: CGPoint(x: 345, y: ay - 13)); ctx.strokePath()

    // Text (drawn in a non-flipped AppKit context; topY measured from the top).
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = g
    func text(_ s: String, _ font: NSFont, _ color: NSColor, topY: CGFloat) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let sz = a.size()
        a.draw(at: CGPoint(x: (W - sz.width) / 2, y: (H - topY) - sz.height))
    }
    text("OCR Studio", .systemFont(ofSize: 30, weight: .bold),
         NSColor(red: 0.10, green: 0.16, blue: 0.34, alpha: 1), topY: 30)
    text("Drag the app onto the Applications folder to install.",
         .systemFont(ofSize: 13, weight: .medium),
         NSColor(red: 0.32, green: 0.38, blue: 0.50, alpha: 1), topY: 74)
    NSGraphicsContext.current = nil

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, image, nil)
    CGImageDestinationFinalize(dst)
}

let dir = CommandLine.arguments[1]
writePNG(render(1), to: dir + "/bg.png")
writePNG(render(2), to: dir + "/bg@2x.png")
print("wrote backgrounds to \(dir)")
