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
func chineseFont(size: CGFloat, bold: Bool = true) -> CTFont {
    let names = bold
        ? ["PingFangSC-Semibold", "PingFang SC", "STHeitiSC-Medium", "HiraginoSansGB-W6", "Helvetica"]
        : ["PingFangSC-Regular", "PingFang SC", "STHeitiSC-Light", "HiraginoSansGB-W3", "Helvetica"]
    let probe: [UniChar] = Array("译".utf16)
    for name in names {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        var glyphs = [CGGlyph](repeating: 0, count: probe.count)
        if CTFontGetGlyphsForCharacters(font, probe, &glyphs, probe.count), glyphs[0] != 0 {
            return font
        }
    }
    return CTFontCreateWithName("PingFang SC" as CFString, size, nil)
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

/// Draw a single centered glyph and return the box it occupied.
@discardableResult
func drawCenteredGlyph(
    _ text: String,
    in context: CGContext,
    canvas: CGFloat,
    fontSize: CGFloat,
    color: CGColor,
    yOffset: CGFloat = 0
) -> CGRect {
    let font = chineseFont(size: fontSize)
    // CoreText attribute names directly, so this tool needs neither AppKit nor UIKit.
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let ascent = CTFontGetAscent(font)
    let descent = CTFontGetDescent(font)

    // Optical centering: use the glyph ink box, not the line box, so the character
    // sits in the middle of the tile instead of slightly high (CJK fonts have a deep
    // descent reserved for Latin descenders).
    let originX = (canvas - bounds.width) / 2 - bounds.minX
    let originY = (canvas - (ascent + descent)) / 2 + descent - bounds.minY + yOffset

    context.textPosition = CGPoint(x: originX, y: originY)
    CTLineDraw(line, context)
    return CGRect(x: originX + bounds.minX, y: originY + bounds.minY, width: bounds.width, height: bounds.height)
}

/// The macOS-style rounded tile, drawn as a path so it scales to any size.
func drawTile(in context: CGContext, canvas: CGFloat) {
    let inset = canvas * 0.08
    let rect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = rect.width * 0.2237 // Apple's squircle-ish corner ratio

    let path = CGPath(
        roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    context.saveGState()
    context.addPath(path)
    context.clip()

    // Vertical gradient: deep indigo at the top, a lighter blue at the bottom.
    let colors = [
        CGColor(red: 0.145, green: 0.243, blue: 0.541, alpha: 1.0),
        CGColor(red: 0.192, green: 0.400, blue: 0.800, alpha: 1.0)
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

    // A hairline highlight so the tile reads as a physical object at large sizes.
    context.saveGState()
    context.addPath(path)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    context.setLineWidth(max(1, canvas * 0.004))
    context.strokePath()
    context.restoreGState()
}

// MARK: - App icon (1024pt master)

let masterSize = 1024
let master = makeContext(width: masterSize, height: masterSize)
let masterCanvas = CGFloat(masterSize)
// Transparent margin around the tile keeps the icon from looking oversized in the Dock.
drawTile(in: master, canvas: masterCanvas)
drawCenteredGlyph(
    "译",
    in: master,
    canvas: masterCanvas,
    fontSize: masterCanvas * 0.52,
    color: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    yOffset: masterCanvas * 0.005
)
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

// Rendered with transparent padding and a black glyph so macOS can treat it as a
// template image: it is tinted black on a light menu bar and white on a dark one.
let statusPixels = 44 // 22pt @2x
let statusContext = makeContext(width: statusPixels, height: statusPixels)
let statusCanvas = CGFloat(statusPixels)
drawCenteredGlyph(
    "译",
    in: statusContext,
    canvas: statusCanvas,
    fontSize: statusCanvas * 0.80,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
)
if let statusImage = statusContext.makeImage() {
    writePNG(statusImage, to: outputDirectory + "/pdf2zh-status.png")
}

print("图标已渲染到 \(outputDirectory)")
