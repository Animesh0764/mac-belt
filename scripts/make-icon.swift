// Draws Mac Belt's app icon: a leather belt with a buckle.
//   swift scripts/make-icon.swift <out.png> [size]
// scripts/make-icon.sh turns it into Resources/AppIcon.icns.
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let S = CGFloat(args.count > 2 ? Double(args[2]) ?? 1024 : 1024)
let k = S / 1024  // everything below is drawn on a 1024 grid

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: k, y: k)

func gradient(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Squircle tile on Apple's icon grid (824pt tile, centred, soft shadow).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0xFF8A3D)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
gradient([rgb(0xFFC15A), rgb(0xFF7A3D), rgb(0xF0524A)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))

// The strap: full width, slightly below centre.
let strap = CGRect(x: 60, y: 372, width: 904, height: 236)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x5A1E0E, 0.45))
ctx.setFillColor(rgb(0x5B3420)); ctx.fill(strap)
ctx.restoreGState()
ctx.saveGState(); ctx.clip(to: strap)
gradient([rgb(0x7A4A2E), rgb(0x5B3420), rgb(0x47271A)], from: CGPoint(x: 0, y: strap.maxY), to: CGPoint(x: 0, y: strap.minY))
ctx.restoreGState()
// Stitching.
ctx.setStrokeColor(rgb(0xE9B98A, 0.9)); ctx.setLineWidth(7); ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [22, 18])
for y in [strap.maxY - 26, strap.minY + 26] {
    ctx.move(to: CGPoint(x: 40, y: y)); ctx.addLine(to: CGPoint(x: 984, y: y))
}
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// Buckle in the middle: a thick silver frame with a prong.
let frame = CGRect(x: 399, y: 318, width: 226, height: 344)
let framePath = CGPath(roundedRect: frame, cornerWidth: 64, cornerHeight: 64, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: rgb(0x000000, 0.35))
ctx.addPath(framePath); ctx.setLineWidth(46); ctx.setStrokeColor(rgb(0xC9CED6)); ctx.strokePath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(framePath); ctx.setLineWidth(46); ctx.replacePathWithStrokedPath(); ctx.clip()
gradient([rgb(0xFFFFFF), rgb(0xD5DAE1), rgb(0x9AA1AC)], from: CGPoint(x: 0, y: frame.maxY + 23), to: CGPoint(x: 0, y: frame.minY - 23))
ctx.restoreGState()
// Prong.
let prong = CGPath(roundedRect: CGRect(x: 493, y: 472, width: 200, height: 36), cornerWidth: 18, cornerHeight: 18, transform: nil)
ctx.addPath(prong); ctx.clip()
gradient([rgb(0xF4F6F8), rgb(0xA7AEB8)], from: CGPoint(x: 0, y: 508), to: CGPoint(x: 0, y: 472))
ctx.resetClip()
ctx.restoreGState()  // tile clip

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
