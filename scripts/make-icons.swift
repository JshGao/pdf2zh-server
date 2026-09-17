// scripts/make-icons.swift
// Renders the app's icon set with CoreGraphics + CoreText. No SVG toolchain and no
// dependency on macOS's private SVG renderer: every size is rasterised from the same
// vector description, so the .icns stays sharp and the build is reproducible.
//
//   make-icons <output-directory>
//
// Produces:
//   AppIcon.iconset/  -> fed to `iconutil -c icns`
//   AppIcon.icns      -> copied into the .app by build.sh
//   pdf2zh-status.png -> status bar template image (22pt, black on transparent)
//   icon-preview.png  -> 256px preview for the README
//
// The design is a deep-blue rounded tile carrying the character 译 ("translate").
// It deliberately avoids upstream artwork: this is an unofficial launcher, not a
// redistribution of PDFMathTranslate assets.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Helpers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法: make-icons <输出目录>\n".utf8))
    exit(1)
}
let outputDirectory = arguments[1]
let fileManager = FileManager.default

try? fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)


func makeContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write(Data("无法创建位图上下文\n".utf8))
        exit(1)
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setShouldSmoothFonts(true)
    return context
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        FileHandle.standardError.write(Data("无法写入 \(path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("无法完成 \(path)\n".utf8))
        exit(1)
    }
}

/// The app's mark: two interlocking loops, drawn from the vector paths in
/// assets/download.svg (hand-drawn by the project author).
///
/// The artwork is defined in a 320x240 viewBox with SVG's y-down convention. Paths are
/// converted once, by hand, with y flipped (y -> 240 - y) so they can live in CoreGraphics'
/// y-up space; nothing is re-derived at runtime, which keeps this the single source of truth
/// and avoids pulling an SVG parser into the build.
///
/// Because the two subpaths interlock rather than overlap, they must be filled with the
/// **non-zero** winding rule. Even-odd would punch the overlap out; non-zero keeps it solid,
/// which is exactly what makes the loops read as one continuous band.
func interlockingLoopsPath() -> CGPath {
    let path = CGMutablePath()

    // Upper-left loop travelling through the middle.
    path.move(to: CGPoint(x: 296, y: 9))
    path.addCurve(to: CGPoint(x: 254, y: -3), control1: CGPoint(x: 284, y: 1), control2: CGPoint(x: 269, y: -3))
    path.addCurve(to: CGPoint(x: 169, y: 79), control1: CGPoint(x: 207, y: -3), control2: CGPoint(x: 169, y: 33))
    path.addCurve(to: CGPoint(x: 254, y: 162), control1: CGPoint(x: 169, y: 125), control2: CGPoint(x: 207, y: 162))
    path.addCurve(to: CGPoint(x: 305, y: 145), control1: CGPoint(x: 273, y: 162), control2: CGPoint(x: 289, y: 156))
    path.addLine(to: CGPoint(x: 387, y: 89))
    path.addCurve(to: CGPoint(x: 389, y: 57), control1: CGPoint(x: 399, y: 81), control2: CGPoint(x: 400, y: 67))
    path.addCurve(to: CGPoint(x: 358, y: 56), control1: CGPoint(x: 381, y: 49), control2: CGPoint(x: 369, y: 49))
    path.addLine(to: CGPoint(x: 278, y: 111))
    path.addCurve(to: CGPoint(x: 254, y: 120), control1: CGPoint(x: 270, y: 117), control2: CGPoint(x: 262, y: 120))
    path.addCurve(to: CGPoint(x: 214, y: 79), control1: CGPoint(x: 231, y: 120), control2: CGPoint(x: 214, y: 102))
    path.addCurve(to: CGPoint(x: 257, y: 35), control1: CGPoint(x: 214, y: 55), control2: CGPoint(x: 232, y: 36))
    path.closeSubpath()

    // Lower-right loop threading back through it.
    path.move(to: CGPoint(x: 328, y: 149))
    path.addCurve(to: CGPoint(x: 378, y: 163), control1: CGPoint(x: 343, y: 158), control2: CGPoint(x: 360, y: 163))
    path.addCurve(to: CGPoint(x: 470, y: 80), control1: CGPoint(x: 429, y: 163), control2: CGPoint(x: 470, y: 127))
    path.addCurve(to: CGPoint(x: 380, y: -3), control1: CGPoint(x: 470, y: 33), control2: CGPoint(x: 432, y: -3))
    path.addCurve(to: CGPoint(x: 306, y: 20), control1: CGPoint(x: 352, y: -4), control2: CGPoint(x: 328, y: 4))
    path.addLine(to: CGPoint(x: 242, y: 66))
    path.addCurve(to: CGPoint(x: 239, y: 96), control1: CGPoint(x: 231, y: 74), control2: CGPoint(x: 229, y: 86))
    path.addCurve(to: CGPoint(x: 268, y: 98), control1: CGPoint(x: 247, y: 105), control2: CGPoint(x: 258, y: 105))
    path.addLine(to: CGPoint(x: 344, y: 44))
    path.addCurve(to: CGPoint(x: 410, y: 49), control1: CGPoint(x: 365, y: 29), control2: CGPoint(x: 392, y: 32))
    path.addCurve(to: CGPoint(x: 414, y: 107), control1: CGPoint(x: 430, y: 67), control2: CGPoint(x: 430, y: 91))
    path.addCurve(to: CGPoint(x: 373, y: 118), control1: CGPoint(x: 404, y: 118), control2: CGPoint(x: 390, y: 122))
    path.closeSubpath()

    return path
}

/// Scale the mark so its ink box fits `box`, centred on the box's midpoint.
///
/// Fitting by measured ink bounds rather than by the viewBox means the artwork's own
/// margins are ignored automatically: the mark always fills the space it is given,
/// whatever padding the SVG happens to carry.
func fittedMark(in box: CGRect, fill: CGFloat) -> CGPath {
    let source = interlockingLoopsPath()
    let ink = source.boundingBoxOfPath
    guard ink.width > 0, ink.height > 0 else { return source }

    let scale = min(box.width * fill / ink.width, box.height * fill / ink.height)
    var transform = CGAffineTransform(
        translationX: box.midX, y: box.midY
    )
    .scaledBy(x: scale, y: scale)
    .translatedBy(x: -ink.midX, y: -ink.midY)

    return source.copy(using: &transform) ?? source
}

/// The status bar mark: the interlocking loops, filled.
func drawFramedMark(in context: CGContext, size: CGSize, color: CGColor) {
    context.saveGState()
    context.addPath(fittedMark(in: CGRect(origin: .zero, size: size), fill: 0.94))
    context.setFillColor(color)
    // Non-zero: the two loops interlock, so their overlap must stay solid.
    context.fillPath()
    context.restoreGState()
}

/// The app icon: a liquid-glass tile carrying the mark.
///
/// macOS 26 ships `NSGlassEffectView`, but that is a view-level material and cannot be
/// rendered offscreen into an .icns, so the glass is composited by hand. Five layers, in
/// order, which is what sells the material:
///
/// 1. a diagonal blue gradient for the body of the glass,
/// 2. a radial highlight from the upper edge — the specular sheen light leaves on glass,
/// 3. a cool reflection rising from the lower edge, the light that bounced off the surface
///    the icon sits on,
/// 4. the mark, with a soft dark shadow behind it so it reads as set *into* the glass
///    rather than painted on top, and a subtle white-to-cool-white gradient for sheen,
/// 5. two rim strokes: a bright hairline on the outer edge and a dimmer one just inside it,
///    which is what gives the tile visible thickness.
///
/// Layers 2, 3 and 5 are the whole trick — a flat gradient alone reads as plastic.
func drawAppTile(in context: CGContext, canvas: CGFloat) {
    let inset = canvas * 0.055
    let rect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = rect.width * 0.2237 // Apple's squircle-ish corner ratio
    let tile = CGPath(
        roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    // 1) Body of the glass.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let bodyColors = [
        CGColor(red: 0.36, green: 0.66, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.05, green: 0.22, blue: 0.60, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bodyColors, locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // 2) Specular sheen from above.
    let sheenCenter = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.10)
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.55),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            gradient,
            startCenter: sheenCenter, startRadius: 0,
            endCenter: sheenCenter, endRadius: rect.width * 0.72,
            options: []
        )
    }

    // 3) Reflected light rising from below.
    let bounceCenter = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.06)
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.60, green: 0.82, blue: 1.00, alpha: 0.28),
            CGColor(red: 0.60, green: 0.82, blue: 1.00, alpha: 0.0)
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            gradient,
            startCenter: bounceCenter, startRadius: 0,
            endCenter: bounceCenter, endRadius: rect.width * 0.55,
            options: []
        )
    }
    context.restoreGState()

    // 4) The mark, engraved into the glass.
    let markPath = fittedMark(in: rect, fill: 0.80)
    context.saveGState()
    context.addPath(markPath)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setShadow(
        offset: CGSize(width: 0, height: -canvas * 0.012),
        blur: canvas * 0.030,
        color: CGColor(red: 0.0, green: 0.05, blue: 0.20, alpha: 0.55)
    )
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(markPath)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1.0),
            CGColor(red: 0.86, green: 0.93, blue: 1.00, alpha: 1.0)
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }
    context.restoreGState()

    // 5) Glass thickness: bright outer hairline plus a dimmer inner one.
    context.saveGState()
    context.addPath(tile)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
    context.setLineWidth(canvas * 0.006)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.addPath(
        CGPath(
            roundedRect: rect.insetBy(dx: canvas * 0.010, dy: canvas * 0.010),
            cornerWidth: radius * 0.95, cornerHeight: radius * 0.95, transform: nil
        )
    )
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    context.setLineWidth(canvas * 0.010)
    context.strokePath()
    context.restoreGState()
}

// MARK: - App icon (1024pt master)

let masterSize = 1024
let master = makeContext(width: masterSize, height: masterSize)
let masterCanvas = CGFloat(masterSize)
// Transparent margin around the tile keeps the icon from looking oversized in the Dock.
drawAppTile(in: master, canvas: masterCanvas)
guard let masterImage = master.makeImage() else {
    FileHandle.standardError.write(Data("无法生成主图标位图\n".utf8))
    exit(1)
}

// MARK: - iconset + icns

let iconsetDirectory = outputDirectory + "/AppIcon.iconset"
try? fileManager.removeItem(atPath: iconsetDirectory)
try? fileManager.createDirectory(atPath: iconsetDirectory, withIntermediateDirectories: true)

// (filename, pixel size) — the exact list `iconutil` expects.
let iconVariants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, pixels) in iconVariants {
    let context = makeContext(width: pixels, height: pixels)
    context.interpolationQuality = .high
    context.draw(masterImage, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let image = context.makeImage() else { continue }
    writePNG(image, to: iconsetDirectory + "/" + filename)
}

// A 256px preview for the README.
let previewContext = makeContext(width: 256, height: 256)
previewContext.interpolationQuality = .high
previewContext.draw(masterImage, in: CGRect(x: 0, y: 0, width: 256, height: 256))
if let preview = previewContext.makeImage() {
    writePNG(preview, to: outputDirectory + "/icon-preview.png")
}

// MARK: - Status bar image

// Black mark on transparent background so macOS can treat it as a template image: it is
// tinted black on a light menu bar and white on a dark one.
//
// The canvas is cropped tight to the mark's ink bounds rather than being square, so the
// image's own aspect ratio *is* the mark's aspect ratio. The app then only has to pick a
// height and let the width follow (see main.swift) — with a square canvas it would have to
// guess, and a 1.8:1 mark in a 1:1 image gets scaled down to fit the wrong dimension.
//
// Rendered at 2x the display size so it stays crisp on Retina.
let statusInk = interlockingLoopsPath().boundingBoxOfPath
let statusHeightPt: CGFloat = 16
let statusHeightPx = Int((statusHeightPt * 2).rounded())
let statusWidthPx = Int((statusHeightPt * 2 * statusInk.width / statusInk.height).rounded())
let statusContext = makeContext(width: statusWidthPx, height: statusHeightPx)
drawFramedMark(
    in: statusContext,
    size: CGSize(width: statusWidthPx, height: statusHeightPx),
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
)
if let statusImage = statusContext.makeImage() {
    writePNG(statusImage, to: outputDirectory + "/pdf2zh-status.png")
}

print("图标已渲染到 \(outputDirectory)")
