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

/// A font that actually has the glyph we need; Helvetica silently renders .notdef.
func chineseFont(size: CGFloat, bold: Bool = true, character: String = "文") -> CTFont {
    let names = bold
        ? ["PingFangSC-Semibold", "PingFang SC", "STHeitiSC-Medium", "HiraginoSansGB-W6", "Helvetica"]
        : ["PingFangSC-Regular", "PingFang SC", "STHeitiSC-Light", "HiraginoSansGB-W3", "Helvetica"]
    let probe: [UniChar] = Array(character.utf16)
    for name in names {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        var glyphs = [CGGlyph](repeating: 0, count: probe.count)
        if CTFontGetGlyphsForCharacters(font, probe, &glyphs, probe.count), glyphs[0] != 0 {
            return font
        }
    }
    return CTFontCreateWithName("PingFang SC" as CFString, size, nil)
}

/// Helvetica Bold: a squarer, heavier A than PingFang's Latin, which is what keeps the
/// Latin half from looking weak next to a dense hanzi.
func latinFont(size: CGFloat) -> CTFont {
    CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
}

/// Build a single-run line with CoreText attribute names directly, so this tool needs
/// neither AppKit nor UIKit.
func makeLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
    ]
    return CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes)
    )
}

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
func drawFramedMark(in context: CGContext, canvas: CGFloat, color: CGColor) {
    let strokeWidth = canvas * 0.072
    // Inset by half the stroke so the outline's outer edge lands on the canvas edge
    // rather than being clipped by it.
    let inset = strokeWidth / 2 + canvas * 0.032
    let rect = CGRect(
        x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2
    )
    let radius = canvas * 0.25

    context.saveGState()
    context.addPath(
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    )
    context.setStrokeColor(color)
    context.setLineWidth(strokeWidth)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()

    let hanSize = canvas * 0.40
    let latinSize = hanSize * 1.24
    let hanLine = makeLine("文", font: chineseFont(size: hanSize), color: color)
    let latinLine = makeLine("A", font: latinFont(size: latinSize), color: color)
    let hanInk = CTLineGetBoundsWithOptions(hanLine, .useGlyphPathBounds)
    let latinInk = CTLineGetBoundsWithOptions(latinLine, .useGlyphPathBounds)

    let gap = canvas * 0.02
    let totalWidth = hanInk.width + gap + latinInk.width
    let startX = rect.midX - totalWidth / 2
    // Both characters sit on a common optical centre; the shift is the same hanzi
    // correction described in drawFramedMark.
    let shift = -0.010 * hanSize

    context.textPosition = CGPoint(
        x: startX - hanInk.minX,
        y: rect.midY - hanInk.height / 2 - hanInk.minY + shift
    )
    CTLineDraw(hanLine, context)
    context.textPosition = CGPoint(
        x: startX + hanInk.width + gap - latinInk.minX,
        y: rect.midY - latinInk.height / 2 - latinInk.minY + shift
    )
    CTLineDraw(latinLine, context)
}

/// The app icon: a rounded tile split into a blue half and a light half, carrying the
/// same 文 / A pairing as the status bar mark. The two-tone split is what gives the icon
/// its depth — a single flat colour with a character on it reads as a placeholder.
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

    // Right half: cool light grey, the "target language" side.
    context.setFillColor(CGColor(red: 0.847, green: 0.867, blue: 0.894, alpha: 1))
    context.fill(rect)

    // Left half: blue gradient, the "source language" side.
    let splitRatio: CGFloat = 0.52
    let blue = CGRect(
        x: rect.minX, y: rect.minY, width: rect.width * splitRatio, height: rect.height
    )
    context.saveGState()
    context.clip(to: blue)
    let colors = [
        CGColor(red: 0.129, green: 0.420, blue: 0.882, alpha: 1.0),
        CGColor(red: 0.086, green: 0.310, blue: 0.749, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: blue.minX, y: blue.maxY),
            end: CGPoint(x: blue.maxX, y: blue.minY),
            options: []
        )
    }
    context.restoreGState()
    context.restoreGState()

    // 文 in white on the blue side, A in near-black on the light side. Each is centred on
    // its own half, which is why the two halves are measured independently.
    let hanSize = canvas * 0.30
    let latinSize = canvas * 0.355
    let hanLine = makeLine(
        "文", font: chineseFont(size: hanSize),
        color: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    )
    let latinLine = makeLine(
        "A", font: latinFont(size: latinSize),
        color: CGColor(red: 0.180, green: 0.208, blue: 0.267, alpha: 1)
    )
    let hanInk = CTLineGetBoundsWithOptions(hanLine, .useGlyphPathBounds)
    let latinInk = CTLineGetBoundsWithOptions(latinLine, .useGlyphPathBounds)
    let shift = -0.010 * hanSize

    context.textPosition = CGPoint(
        x: blue.midX - hanInk.width / 2 - hanInk.minX,
        y: rect.midY - hanInk.height / 2 - hanInk.minY + shift
    )
    CTLineDraw(hanLine, context)

    let lightHalfMidX = (blue.maxX + rect.maxX) / 2
    context.textPosition = CGPoint(
        x: lightHalfMidX - latinInk.width / 2 - latinInk.minX,
        y: rect.midY - latinInk.height / 2 - latinInk.minY + shift
    )
    CTLineDraw(latinLine, context)
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
