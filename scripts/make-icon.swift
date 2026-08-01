#!/usr/bin/env swift
//
// Generates Resources/Whisperoid.icns.
//
// The icon is drawn rather than authored in a design tool so it stays
// reproducible and reviewable in source. It reuses the same `waveform` SF
// Symbol as the menu bar, so the Dock icon and the status item are visibly the
// same application.
//
// Usage: swift scripts/make-icon.swift [output.icns]

import AppKit
import Foundation

// Apple's macOS icon grid: the rounded shape occupies roughly 80% of the
// canvas, leaving room for the system's shadow.
let canvasRatio: CGFloat = 0.816
// Standard approximation of the continuous "squircle" corner.
let cornerRatio: CGFloat = 0.2237

func drawIcon(side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let shapeSide = side * canvasRatio
    let origin = (side - shapeSide) / 2
    let rect = CGRect(x: origin, y: origin, width: shapeSide, height: shapeSide)
    let radius = shapeSide * cornerRatio

    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Indigo to violet, which stays legible against both light and dark Docks.
    context.saveGState()
    context.addPath(shape)
    context.clip()

    let colors = [
        NSColor(srgbRed: 0.35, green: 0.30, blue: 0.86, alpha: 1).cgColor,
        NSColor(srgbRed: 0.53, green: 0.24, blue: 0.78, alpha: 1).cgColor,
    ] as CFArray
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])
    {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // A soft highlight across the top edge, which is what stops a flat gradient
    // reading as a sticker rather than an icon.
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let sheen = CGGradient(
           colorsSpace: space,
           colors: [
               NSColor(white: 1, alpha: 0.22).cgColor,
               NSColor(white: 1, alpha: 0).cgColor,
           ] as CFArray,
           locations: [0, 1]
       )
    {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.midY),
            options: []
        )
    }
    context.restoreGState()

    // Hairline edge so the shape keeps definition on a light background.
    context.saveGState()
    context.addPath(shape)
    context.setStrokeColor(NSColor(white: 0, alpha: 0.12).cgColor)
    context.setLineWidth(max(side * 0.004, 0.5))
    context.strokePath()
    context.restoreGState()

    drawWaveform(in: rect, context: context, side: side)

    image.unlockFocus()
    return image
}

func drawWaveform(in rect: CGRect, context: CGContext, side: CGFloat) {
    let pointSize = rect.width * 0.62
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)

    guard let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return }

    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    let bounds = NSRect(origin: .zero, size: symbol.size)
    symbol.draw(in: bounds)
    bounds.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let target = NSRect(
        x: rect.midX - tinted.size.width / 2,
        y: rect.midY - tinted.size.height / 2,
        width: tinted.size.width,
        height: tinted.size.height
    )

    // A faint drop shadow lifts the glyph off the gradient.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -side * 0.006),
        blur: side * 0.014,
        color: NSColor(white: 0, alpha: 0.28).cgColor
    )
    tinted.draw(in: target)
    context.restoreGState()
}

func png(from image: NSImage, pixels: Int) -> Data? {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    representation.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    return representation.representation(using: .png, properties: [:])
}

// MARK: - Entry point

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1
    ? arguments[1]
    : FileManager.default.currentDirectoryPath + "/Resources/Whisperoid.icns"

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Whisperoid.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The names are fixed by iconutil.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = drawIcon(side: CGFloat(variant.pixels))
    guard let data = png(from: image, pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

// Keep the largest rendering for visual review.
if let preview = png(from: drawIcon(side: 512), pixels: 512) {
    try preview.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "whisperoid-icon-preview.png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("wrote \(outputPath)")
print("preview \(NSTemporaryDirectory())whisperoid-icon-preview.png")
