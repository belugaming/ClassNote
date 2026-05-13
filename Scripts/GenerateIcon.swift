#!/usr/bin/env swift
// Generates the ClassNote app icon at 1024×1024 and writes every size required
// by macOS AppIcon.appiconset. Run: `swift Scripts/GenerateIcon.swift`
//
// Concept: warm amber squircle, soft vertical gradient, a centered waveform with
// a subtle EN ⇄ 中 translation cue underneath. Colors mirror Theme.swift.

import AppKit
import Foundation

// MARK: - Config

let outputDir = FileManager.default.currentDirectoryPath
    + "/Resources/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: outputDir,
                                          withIntermediateDirectories: true)

let amberTop    = NSColor(srgbRed: 0.98, green: 0.70, blue: 0.20, alpha: 1.0)
let amberBottom = NSColor(srgbRed: 0.93, green: 0.48, blue: 0.10, alpha: 1.0)
let highlight   = NSColor(srgbRed: 1.00, green: 0.85, blue: 0.50, alpha: 0.35)
let textColor   = NSColor.white
let softText    = NSColor(white: 1.0, alpha: 0.88)

// MARK: - Draw

func renderIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Squircle background with gradient
    let radius = size * 0.23
    let path = CGPath(roundedRect: rect.insetBy(dx: size * 0.02, dy: size * 0.02),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [amberTop.cgColor, amberBottom.cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                            start: CGPoint(x: size/2, y: size),
                            end: CGPoint(x: size/2, y: 0),
                            options: [])

    // Top highlight sheen
    let sheen = CGRect(x: 0, y: size * 0.55, width: size, height: size * 0.45)
    let sheenColors = [highlight.cgColor, NSColor.clear.cgColor] as CFArray
    let sheenGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: sheenColors, locations: [0, 1])!
    ctx.drawLinearGradient(sheenGrad,
                            start: CGPoint(x: size/2, y: sheen.maxY),
                            end: CGPoint(x: size/2, y: sheen.minY),
                            options: [])
    ctx.restoreGState()

    // Thin inner stroke for glassy edge
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.28).cgColor)
    ctx.setLineWidth(size * 0.012)
    ctx.strokePath()
    ctx.restoreGState()

    // Centered waveform
    drawWaveform(ctx: ctx, size: size)

    // Bilingual EN ⇄ 中 cue
    drawTranslationCue(ctx: ctx, size: size)

    return img
}

func drawWaveform(ctx: CGContext, size: CGFloat) {
    // Series of vertical rounded bars forming a symmetric waveform.
    let barCount = 9
    let centerX = size / 2
    let centerY = size * 0.55
    let maxHeight = size * 0.42
    let spacing = size * 0.055
    let barWidth = size * 0.035

    // Amplitude pattern (centered peak)
    let amplitudes: [CGFloat] = [0.25, 0.42, 0.60, 0.82, 1.0, 0.82, 0.60, 0.42, 0.25]

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.005),
                  blur: size * 0.02,
                  color: NSColor(white: 0, alpha: 0.25).cgColor)
    ctx.setFillColor(textColor.cgColor)

    for i in 0..<barCount {
        let offset = CGFloat(i - barCount / 2)
        let h = max(maxHeight * amplitudes[i], size * 0.06)
        let rect = CGRect(
            x: centerX + offset * spacing - barWidth / 2,
            y: centerY - h / 2,
            width: barWidth,
            height: h
        )
        let p = CGPath(roundedRect: rect,
                        cornerWidth: barWidth / 2,
                        cornerHeight: barWidth / 2,
                        transform: nil)
        ctx.addPath(p)
        ctx.fillPath()
    }
    ctx.restoreGState()
}

func drawTranslationCue(ctx: CGContext, size: CGFloat) {
    // "A ⇄ 文" near the bottom, small but readable even at 128px
    let yBaseline = size * 0.18
    let fontSize = size * 0.13

    // "A"
    drawCenteredGlyph("A", at: CGPoint(x: size * 0.36, y: yBaseline), fontSize: fontSize,
                      weight: .heavy, color: softText)
    // Arrow
    drawArrow(ctx: ctx,
              center: CGPoint(x: size * 0.50, y: yBaseline + fontSize * 0.4),
              width: size * 0.09,
              thickness: size * 0.012,
              color: softText)
    // "文"
    drawCenteredGlyph("文", at: CGPoint(x: size * 0.64, y: yBaseline), fontSize: fontSize,
                      weight: .bold, color: softText)
}

func drawCenteredGlyph(_ str: String, at point: CGPoint, fontSize: CGFloat,
                       weight: NSFont.Weight, color: NSColor) {
    let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style
    ]
    let s = str as NSString
    let size = s.size(withAttributes: attrs)
    let rect = CGRect(x: point.x - size.width / 2,
                      y: point.y,
                      width: size.width,
                      height: size.height)
    s.draw(in: rect, withAttributes: attrs)
}

func drawArrow(ctx: CGContext, center: CGPoint, width: CGFloat,
               thickness: CGFloat, color: NSColor) {
    ctx.saveGState()
    ctx.setStrokeColor(color.cgColor)
    ctx.setFillColor(color.cgColor)
    ctx.setLineWidth(thickness)
    ctx.setLineCap(.round)

    // Main horizontal line
    ctx.move(to: CGPoint(x: center.x - width / 2, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x + width / 2, y: center.y))
    ctx.strokePath()

    // Right arrowhead
    let headSize = width * 0.28
    ctx.move(to: CGPoint(x: center.x + width / 2, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x + width / 2 - headSize, y: center.y + headSize * 0.6))
    ctx.move(to: CGPoint(x: center.x + width / 2, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x + width / 2 - headSize, y: center.y - headSize * 0.6))
    ctx.strokePath()

    // Left arrowhead (making it a double-arrow)
    ctx.move(to: CGPoint(x: center.x - width / 2, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x - width / 2 + headSize, y: center.y + headSize * 0.6))
    ctx.move(to: CGPoint(x: center.x - width / 2, y: center.y))
    ctx.addLine(to: CGPoint(x: center.x - width / 2 + headSize, y: center.y - headSize * 0.6))
    ctx.strokePath()

    ctx.restoreGState()
}

// MARK: - Export

func pngData(from image: NSImage, pixelSize: CGFloat) -> Data? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                pixelsWide: Int(pixelSize),
                                pixelsHigh: Int(pixelSize),
                                bitsPerSample: 8,
                                samplesPerPixel: 4,
                                hasAlpha: true,
                                isPlanar: false,
                                colorSpaceName: .deviceRGB,
                                bytesPerRow: 0,
                                bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

struct IconSpec {
    let filename: String
    let pixelSize: Int
    let size: Int
    let scale: Int
}

// Full macOS AppIcon set
let specs: [IconSpec] = [
    .init(filename: "icon_16x16.png",       pixelSize: 16,   size: 16,  scale: 1),
    .init(filename: "icon_16x16@2x.png",    pixelSize: 32,   size: 16,  scale: 2),
    .init(filename: "icon_32x32.png",       pixelSize: 32,   size: 32,  scale: 1),
    .init(filename: "icon_32x32@2x.png",    pixelSize: 64,   size: 32,  scale: 2),
    .init(filename: "icon_128x128.png",     pixelSize: 128,  size: 128, scale: 1),
    .init(filename: "icon_128x128@2x.png",  pixelSize: 256,  size: 128, scale: 2),
    .init(filename: "icon_256x256.png",     pixelSize: 256,  size: 256, scale: 1),
    .init(filename: "icon_256x256@2x.png",  pixelSize: 512,  size: 256, scale: 2),
    .init(filename: "icon_512x512.png",     pixelSize: 512,  size: 512, scale: 1),
    .init(filename: "icon_512x512@2x.png",  pixelSize: 1024, size: 512, scale: 2),
]

for spec in specs {
    let img = renderIcon(size: CGFloat(spec.pixelSize))
    guard let data = pngData(from: img, pixelSize: CGFloat(spec.pixelSize)) else {
        FileHandle.standardError.write("Failed to render \(spec.filename)\n".data(using: .utf8)!)
        exit(1)
    }
    let path = "\(outputDir)/\(spec.filename)"
    try data.write(to: URL(fileURLWithPath: path))
    print("✓ \(spec.filename) (\(spec.pixelSize)×\(spec.pixelSize))")
}

// Contents.json
let contents: [String: Any] = [
    "images": specs.map { s in
        [
            "filename": s.filename,
            "idiom": "mac",
            "scale": "\(s.scale)x",
            "size": "\(s.size)x\(s.size)",
        ]
    },
    "info": [
        "author": "xcode",
        "version": 1,
    ] as [String: Any],
]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(outputDir)/Contents.json"))
print("✓ Contents.json")
print("Done. Output: \(outputDir)")
