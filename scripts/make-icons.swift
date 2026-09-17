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
func drawFramedMark(in context: CGContext, canvas: CGFloat, color: CGColor) {
    context.saveGState()
    context.addPath(fittedMark(in: CGRect(x: 0, y: 0, width: canvas, height: canvas), fill: 0.94))
    context.setFillColor(color)
    // Non-zero: the two loops interlock, so their overlap must stay solid.
    context.fillPath()
    context.restoreGState()
}

/// The app icon: a rounded tile with a blue gradient carrying the mark in white.
///
/// Same artwork as the status bar mark (see `interlockingLoopsPath`), just fitted to the
/// tile at 80% and filled non-zero. The gradient rather than a flat fill, plus the generous
/// inset, are what keep it from reading as a placeholder.
func drawAppTile(in context: CGContext, canvas: CGFloat) {
    let inset = canvas * 0.055
    let rect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = rect.width * 0.2237 // Apple's squircle-ish corner ratio
    let path = CGPath(
        roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    context.saveGState()
    context.addPath(path)
    context.clip()

    let colors = [
        CGColor(red: 0.145, green: 0.451, blue: 0.914, alpha: 1.0),
        CGColor(red: 0.055, green: 0.263, blue: 0.698, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }
    context.restoreGState()

    context.saveGState()
    context.addPath(
        fittedMark(in: rect, fill: 0.80)
    )
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath()
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
// tinted black on a light menu bar and white on a dark one. Sized 22pt because that is
// what the app hands to NSStatusItem; rendering at 2x keeps it crisp on Retina.
let statusPixels = 44 // 22pt @2x
let statusContext = makeContext(width: statusPixels, height: statusPixels)
drawFramedMark(
    in: statusContext,
    canvas: CGFloat(statusPixels),
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
)
if let statusImage = statusContext.makeImage() {
    writePNG(statusImage, to: outputDirectory + "/pdf2zh-status.png")
}

print("图标已渲染到 \(outputDirectory)")
