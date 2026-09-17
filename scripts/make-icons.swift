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

/// The infinity outline, filled rather than stroked.
///
/// Filling is what makes the design possible: the mark is a solid block pierced by two
/// circular holes, so the remaining material reads as a single ribbon folding back on
/// itself — the crossing only works because the shape is one continuous area, not two
/// strokes laid over each other.
///
/// The outline is four cubic Beziers forming one closed loop; the lobes meet at the centre
/// point, so the waist comes out of the geometry instead of being faked.
///
/// Proportions are fractions of the canvas, so one description serves 16pt and 1024pt:
///
/// | value | meaning |
/// |---|---|
/// | `width` 0.96 | the mark spans nearly the full menu bar height budget |
/// | `lobeHeightRatio` 0.62 | lobe vertical radius as a fraction of the half width. Lower and the lobes flatten into a bow tie; higher and the 22pt mark grows too tall |
/// | `holeOffset` 0.29 | hole centre distance from the middle, as a fraction of the total width |
/// | `holeRadius` 0.175 | hole radius, as a fraction of the total width |
///
/// The two holes are the entire "design": they carve the solid mass into a ribbon and give
/// the mark a light centre. Earlier revisions tried an interior spiral line for the same
/// effect, which turned to mud at 22pt — holes work where lines do not, because a hole
/// scales as a shape while a 1px line does not.
func infinityOutline(center: CGPoint, width: CGFloat) -> CGPath {
    let halfWidth = width / 2
    let lobeRadius = halfWidth * 0.60
    let controlPull: CGFloat = 0.52
    // The two halves meet across a short vertical segment rather than at a single point.
    // A zero-height waist pinches the ribbon into a spike that all but disappears at 22pt;
    // this keeps the crossing solid while still reading as one continuous band.
    let waistHalf = width * 0.03
    let cx = center.x
    let cy = center.y

    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx - halfWidth, y: cy))
    path.addCurve(
        to: CGPoint(x: cx, y: cy + waistHalf),
        control1: CGPoint(x: cx - halfWidth, y: cy + lobeRadius * 1.55),
        control2: CGPoint(x: cx - halfWidth * controlPull, y: cy + lobeRadius * 1.12)
    )
    path.addCurve(
        to: CGPoint(x: cx + halfWidth, y: cy),
        control1: CGPoint(x: cx + halfWidth * controlPull, y: cy + lobeRadius * 1.12),
        control2: CGPoint(x: cx + halfWidth, y: cy + lobeRadius * 1.55)
    )
    path.addCurve(
        to: CGPoint(x: cx, y: cy - waistHalf),
        control1: CGPoint(x: cx + halfWidth, y: cy - lobeRadius * 1.55),
        control2: CGPoint(x: cx + halfWidth * controlPull, y: cy - lobeRadius * 1.12)
    )
    path.addCurve(
        to: CGPoint(x: cx - halfWidth, y: cy),
        control1: CGPoint(x: cx - halfWidth * controlPull, y: cy - lobeRadius * 1.12),
        control2: CGPoint(x: cx - halfWidth, y: cy - lobeRadius * 1.55)
    )
    path.closeSubpath()
    return path
}

/// Add the two ribbon holes to an outline, returning a path meant to be filled even-odd.
///
/// The holes are tilted ellipses rather than circles: squashing and rotating them along
/// each lobe's axis makes the remaining material read as a twisted band instead of a
/// doughnut with two punctures. The tilt is mirrored per side so the pair stays symmetric
/// about the vertical axis, which is what keeps the mark from looking lopsided.
func infinityRibbon(center: CGPoint, width: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addPath(infinityOutline(center: center, width: width))

    let offset = width * 0.25      // hole centre distance from the middle
    let radiusX = width * 0.134    // along the lobe axis
    let radiusY = width * 0.086    // across it
    let tilt: CGFloat = 38 * .pi / 180

    for sign in [-1.0, 1.0] {
        let hole = CGMutablePath()
        hole.addEllipse(
            in: CGRect(x: -radiusX, y: -radiusY, width: radiusX * 2, height: radiusY * 2)
        )
        var transform = CGAffineTransform(
            translationX: center.x + CGFloat(sign) * offset, y: center.y
        ).rotated(by: tilt * CGFloat(sign))
        if let rotated = hole.copy(using: &transform) {
            path.addPath(rotated)
        }
    }
    return path
}

/// The status bar mark: a solid ∞ pierced by two holes, filled even-odd.
///
/// No stroke anywhere — a stroked version of this shape at 22pt sits next to the solid
/// system glyphs as a hairline, while the filled ribbon has the same blocky presence.
func drawFramedMark(in context: CGContext, canvas: CGFloat, color: CGColor) {
    context.saveGState()
    context.addPath(
        infinityRibbon(center: CGPoint(x: canvas / 2, y: canvas / 2), width: canvas * 0.96)
    )
    context.setFillColor(color)
    context.fillPath(using: .evenOdd)
    context.restoreGState()
}

/// The app icon: a rounded tile with a blue gradient and a heavy white ∞ centred on it.
///
/// The gradient (rather than a flat fill) plus the generous inset are what keep it from
/// reading as a placeholder. The ∞ uses the same filled-ribbon geometry as the status bar
/// mark, filled white with even-odd so the two holes let the blue show through — the two
/// icons read as the same object at different scales.
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
        infinityRibbon(center: CGPoint(x: rect.midX, y: rect.midY), width: rect.width * 0.80)
    )
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath(using: .evenOdd)
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
