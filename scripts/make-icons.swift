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

/// The status bar mark: 文 and A side by side inside a rounded square outline.
///
/// The 文/A pair carries the "Chinese in, Latin out" idea of translation, and the outline
/// gives the mark the graphic weight of a real icon next to the system glyphs — a bare
/// hanzi reads as too light in the menu bar. Every dimension (stroke, corner radius,
/// character sizes, clearances) is a fraction of the canvas, so one description renders
/// correctly at 16pt and at 1024pt with no bitmap scaling anywhere.
///
/// Vertical placement is derived from each character's *ink* box, never from ascent and
/// descent. PingFang reports ascent 1.06em and descent 0.34em, so the typographic line box
/// is 1.4em tall while a hanzi only inks about 0.92em sitting entirely above the baseline;
/// deriving the origin from ascent/descent parks the character visibly high (~13% of the
/// canvas). The extra `shift` then corrects the optical centre, because hanzi carry more
/// stroke weight in their upper half and so still read slightly high when centred exactly.
///
/// The Latin side is set larger than the hanzi on purpose: 文 has many strokes and
/// therefore more ink, while A has three. Matching the two by cap height leaves the pair
/// visibly lopsided, so the A is scaled up until the two halves read at equal weight.
/// The infinity curve, built from four cubic Béziers and centred on `center`.
///
/// The two lobes are drawn as one closed loop, so the waist crossing comes out of the
/// geometry rather than being faked: the left lobe leaves the centre downwards, returns
/// to it from above, and the right lobe mirrors that. Both strokes pass through exactly
/// the same point, which is what makes the crossing read as a single continuous ribbon.
///
/// The proportions are deliberate. `lobeHalfHeight` (0.29 of the canvas) is what separates
/// a real ∞ from a bow tie — flatten it much further and the lobes collapse into two kinked
/// squares. `controlPull` (0.40) keeps the belly round instead of pinching the waist. All
/// values are fractions of the canvas so one description serves 16pt and 1024pt alike.
func infinityPath(center: CGPoint, size: CGFloat) -> CGPath {
    let halfWidth = size * 0.380
    let lobeHalfHeight = size * 0.29
    let controlPull: CGFloat = 0.40
    let cx = center.x
    let cy = center.y

    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx - halfWidth, y: cy))
    // Left lobe: out to the left, over the top, back to the middle.
    path.addCurve(
        to: CGPoint(x: cx, y: cy),
        control1: CGPoint(x: cx - halfWidth, y: cy + lobeHalfHeight * 1.45),
        control2: CGPoint(x: cx - halfWidth * controlPull, y: cy + lobeHalfHeight * 1.05)
    )
    // Right lobe: down from the middle, under the bottom, back out to the right.
    path.addCurve(
        to: CGPoint(x: cx + halfWidth, y: cy),
        control1: CGPoint(x: cx + halfWidth * controlPull, y: cy + lobeHalfHeight * 1.05),
        control2: CGPoint(x: cx + halfWidth, y: cy + lobeHalfHeight * 1.45)
    )
    // Mirror of the above two, below the waist.
    path.addCurve(
        to: CGPoint(x: cx, y: cy),
        control1: CGPoint(x: cx + halfWidth, y: cy - lobeHalfHeight * 1.45),
        control2: CGPoint(x: cx + halfWidth * controlPull, y: cy - lobeHalfHeight * 1.05)
    )
    path.addCurve(
        to: CGPoint(x: cx - halfWidth, y: cy),
        control1: CGPoint(x: cx - halfWidth * controlPull, y: cy - lobeHalfHeight * 1.05),
        control2: CGPoint(x: cx - halfWidth, y: cy - lobeHalfHeight * 1.45)
    )
    path.closeSubpath()
    return path
}

/// The status bar mark: a single stroked ∞. No text, no frame — just the curve.
///
/// The stroke is 8.5% of the canvas, which is what brings the mark to roughly the same
/// optical weight as the surrounding system glyphs. It is drawn as a stroke rather than a
/// filled outline so the two lobes stay open and the mark still reads at 16pt.
func drawFramedMark(in context: CGContext, canvas: CGFloat, color: CGColor) {
    context.saveGState()
    context.addPath(infinityPath(center: CGPoint(x: canvas / 2, y: canvas / 2), size: canvas))
    context.setStrokeColor(color)
    context.setLineWidth(canvas * 0.085)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.strokePath()
    context.restoreGState()
}

/// The app icon: a rounded tile with a blue gradient and a white ∞ centred on it.
///
/// The gradient (rather than a flat fill) plus the generous inset are what keep it from
/// reading as a placeholder. The ∞ is sized to the tile, not the canvas, so the optical
/// margin stays constant no matter how much bleed the icon needs.
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
        CGColor(red: 0.169, green: 0.478, blue: 0.925, alpha: 1.0),
        CGColor(red: 0.075, green: 0.286, blue: 0.722, alpha: 1.0)
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

    // The ∞ is stroked at 9% of the tile, which keeps its ribbon weight in proportion to
    // the tile at every icon size while staying clearly open in the middle.
    context.saveGState()
    context.addPath(
        infinityPath(center: CGPoint(x: rect.midX, y: rect.midY), size: rect.width * 0.82)
    )
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setLineWidth(rect.width * 0.082)
    context.setLineJoin(.round)
    context.setLineCap(.round)
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
