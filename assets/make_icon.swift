import Cocoa
import CoreGraphics

let size = 1024
let width = CGFloat(size)
let height = CGFloat(size)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

let pad: CGFloat = 100
let cardRect = CGRect(x: pad, y: pad, width: width - pad * 2, height: height - pad * 2)
let cornerRadius: CGFloat = 185
let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// Outer drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
ctx.addPath(cardPath)
ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1.0))
ctx.fillPath()
ctx.restoreGState()

// Clip to squircle
ctx.saveGState()
ctx.addPath(cardPath)
ctx.clip()

// Deep obsidian -> midnight violet background gradient (extended across entire canvas)
let bgColors = [
    CGColor(red: 0.13, green: 0.10, blue: 0.24, alpha: 1.0),
    CGColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1.0)
] as CFArray
let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(
    bgGrad,
    start: CGPoint(x: width * 0.2, y: height * 0.9),
    end: CGPoint(x: width * 0.85, y: height * 0.1),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// Subtle ambient glow orbs
let glowColors = [
    CGColor(red: 0.52, green: 0.28, blue: 0.98, alpha: 0.34),
    CGColor(red: 0.52, green: 0.28, blue: 0.98, alpha: 0.0)
] as CFArray
let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0])!
ctx.drawRadialGradient(
    glowGrad,
    startCenter: CGPoint(x: width * 0.36, y: height * 0.56),
    startRadius: 10,
    endCenter: CGPoint(x: width * 0.36, y: height * 0.56),
    endRadius: 360,
    options: []
)

let cyanGlowColors = [
    CGColor(red: 0.16, green: 0.84, blue: 0.98, alpha: 0.28),
    CGColor(red: 0.16, green: 0.84, blue: 0.98, alpha: 0.0)
] as CFArray
let cyanGlow = CGGradient(colorsSpace: colorSpace, colors: cyanGlowColors, locations: [0.0, 1.0])!
ctx.drawRadialGradient(
    cyanGlow,
    startCenter: CGPoint(x: width * 0.68, y: height * 0.50),
    startRadius: 10,
    endCenter: CGPoint(x: width * 0.68, y: height * 0.50),
    endRadius: 320,
    options: []
)

// Render glyph into an alpha mask context so bars + arrow merge seamlessly without winding artifacts
guard let maskCtx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceGray(),
    bitmapInfo: CGImageAlphaInfo.none.rawValue
) else {
    fatalError("Failed to create mask context")
}
maskCtx.setAllowsAntialiasing(true)
maskCtx.setShouldAntialias(true)
maskCtx.setFillColor(gray: 0.0, alpha: 1.0)
maskCtx.fill(CGRect(x: 0, y: 0, width: width, height: height))

maskCtx.setFillColor(gray: 1.0, alpha: 1.0)
maskCtx.setStrokeColor(gray: 1.0, alpha: 1.0)

let barWidth: CGFloat = 52
let barSpacing: CGFloat = 86
let startX: CGFloat = 244
let centerY: CGFloat = 512
let barHeights: [CGFloat] = [170, 340, 460, 270]

for (i, h) in barHeights.enumerated() {
    let x = startX + CGFloat(i) * barSpacing
    let rect = CGRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
    let p = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    maskCtx.addPath(p)
    maskCtx.fillPath()
}

maskCtx.setLineWidth(54)
maskCtx.setLineCap(.round)
maskCtx.setLineJoin(.round)
maskCtx.move(to: CGPoint(x: 604, y: 444))
maskCtx.addLine(to: CGPoint(x: 762, y: 602))
maskCtx.strokePath()

maskCtx.move(to: CGPoint(x: 642, y: 602))
maskCtx.addLine(to: CGPoint(x: 762, y: 602))
maskCtx.addLine(to: CGPoint(x: 762, y: 482))
maskCtx.strokePath()

let glyphMask = maskCtx.makeImage()!

// Outer glow under glyph
ctx.saveGState()
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: glyphMask)
let fgColors = [
    CGColor(red: 0.68, green: 0.44, blue: 1.00, alpha: 1.0),
    CGColor(red: 0.20, green: 0.90, blue: 1.00, alpha: 1.0)
] as CFArray
let fgGrad = CGGradient(colorsSpace: colorSpace, colors: fgColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(
    fgGrad,
    start: CGPoint(x: 230, y: 300),
    end: CGPoint(x: 790, y: 680),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)
ctx.restoreGState()
ctx.endTransparencyLayer()
ctx.restoreGState()

// Subtle inner glass rim highlight
ctx.saveGState()
ctx.addPath(cardPath)
ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.15))
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

ctx.restoreGState()

guard let cgImage = ctx.makeImage() else {
    fatalError("Failed to render CGImage")
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icon-1024.png"
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode PNG")
}
try pngData.write(to: URL(fileURLWithPath: outPath))
print("Generated icon: \(outPath)")
