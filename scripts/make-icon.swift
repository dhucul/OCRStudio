// Generates Resources/AppIcon.icns — a document + scan-beam icon drawn with
// Core Graphics, rendered at every iconset size and packaged via iconutil.
//
// Usage: swift scripts/make-icon.swift [output.icns]
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

func drawIcon(_ s: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Rounded-square ("squircle"-ish) background with a blue gradient.
    let inset = s * 0.05
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let corner = rect.width * 0.2237
    let bg = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: 0.20, green: 0.52, blue: 0.98, alpha: 1),
                                   CGColor(red: 0.10, green: 0.22, blue: 0.60, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY), options: [])

    // White document page.
    let pageW = rect.width * 0.50
    let pageH = pageW * 1.28
    let page = CGRect(x: rect.midX - pageW / 2, y: rect.midY - pageH / 2, width: pageW, height: pageH)
    let pageCorner = pageW * 0.06
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
    ctx.addPath(CGPath(roundedRect: page, cornerWidth: pageCorner, cornerHeight: pageCorner, transform: nil))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Text lines.
    let margin = pageW * 0.15
    let lineH = pageH * 0.052
    ctx.setFillColor(CGColor(red: 0.62, green: 0.67, blue: 0.74, alpha: 1))
    let widths: [CGFloat] = [0.74, 0.92, 0.66, 0.85, 0.55]
    var y = page.maxY - pageH * 0.17
    for w in widths {
        let bar = CGRect(x: page.minX + margin, y: y - lineH,
                         width: (pageW - 2 * margin) * w, height: lineH)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
        ctx.fillPath()
        y -= pageH * 0.135
    }

    // Glowing cyan/green scan beam across the page.
    let beamH = lineH * 0.85
    let beam = CGRect(x: page.minX - pageW * 0.06, y: page.midY - beamH / 2,
                      width: pageW * 1.12, height: beamH)
    ctx.setShadow(offset: .zero, blur: s * 0.025,
                  color: CGColor(red: 0.20, green: 0.95, blue: 0.78, alpha: 0.95))
    ctx.setFillColor(CGColor(red: 0.27, green: 0.96, blue: 0.78, alpha: 1))
    ctx.addPath(CGPath(roundedRect: beam, cornerWidth: beamH / 2, cornerHeight: beamH / 2, transform: nil))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Viewfinder corner brackets (recognition feel).
    let bracketPad = pageW * 0.17
    let arm = pageW * 0.17
    let lw = max(s * 0.012, 1)
    let o = page.insetBy(dx: -bracketPad, dy: -bracketPad)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    func bracket(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
        ctx.move(to: CGPoint(x: p.x, y: p.y + dy * arm))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x + dx * arm, y: p.y))
        ctx.strokePath()
    }
    bracket(CGPoint(x: o.minX, y: o.maxY),  1, -1)   // top-left
    bracket(CGPoint(x: o.maxX, y: o.maxY), -1, -1)   // top-right
    bracket(CGPoint(x: o.minX, y: o.minY),  1,  1)   // bottom-left
    bracket(CGPoint(x: o.maxX, y: o.minY), -1,  1)   // bottom-right

    ctx.restoreGState()
    return ctx.makeImage()!
}

// Render the iconset.
let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Resources/AppIcon.icns"

let tmp = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: tmp)
try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in variants {
    let img = drawIcon(size)
    let url = URL(fileURLWithPath: tmp + "/" + name)
    let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tmp, "-o", outPath]
try! proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(atPath: tmp)
print(proc.terminationStatus == 0 ? "wrote \(outPath)" : "iconutil failed (\(proc.terminationStatus))")
