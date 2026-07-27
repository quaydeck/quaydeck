#!/usr/bin/env swift
//
// Renders Quaydeck's app icon at every size macOS wants, then hands the folder to
// iconutil. Generated rather than committed as a binary so the mark can be adjusted
// in a diff instead of a design tool.
//
// Usage: swift Scripts/make-icon.swift <output.iconset directory>

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

/// Deep harbour navy through to a lighter waterline.
let backgroundTop = CGColor(red: 0.043, green: 0.114, blue: 0.196, alpha: 1)
let backgroundBottom = CGColor(red: 0.078, green: 0.216, blue: 0.325, alpha: 1)
/// Brass, as on a ship's fittings.
let brass = CGColor(red: 0.945, green: 0.769, blue: 0.463, alpha: 1)
let waterTop = CGColor(red: 0.243, green: 0.612, blue: 0.616, alpha: 1)
let waterBottom = CGColor(red: 0.118, green: 0.376, blue: 0.435, alpha: 1)

// MARK: - Drawing

func drawIcon(size: CGFloat, into context: CGContext) {
    let scale = size / 1024
    func s(_ value: CGFloat) -> CGFloat { value * scale }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // The rounded square, inset the way Apple's own icons are rather than bleeding to
    // the edge of the canvas.
    let plate = CGRect(x: s(100), y: s(100), width: s(824), height: s(824))
    let platePath = CGPath(roundedRect: plate, cornerWidth: s(180), cornerHeight: s(180),
                           transform: nil)

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [backgroundTop, backgroundBottom] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: plate.maxY),
                                   end: CGPoint(x: 0, y: plate.minY),
                                   options: [])
    }
    context.restoreGState()

    let centre = CGPoint(x: size / 2, y: size / 2)
    let outerRadius = s(250)
    let ringWidth = s(58)
    let innerRadius = outerRadius - ringWidth / 2

    // The water inside the porthole, with a wave for its surface.
    context.saveGState()
    context.addEllipse(in: CGRect(x: centre.x - innerRadius, y: centre.y - innerRadius,
                                  width: innerRadius * 2, height: innerRadius * 2))
    context.clip()

    let waterLine = centre.y - s(20)
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: centre.x - innerRadius, y: waterLine))
    wave.addCurve(to: CGPoint(x: centre.x, y: waterLine),
                  control1: CGPoint(x: centre.x - innerRadius * 0.55, y: waterLine + s(34)),
                  control2: CGPoint(x: centre.x - innerRadius * 0.45, y: waterLine - s(34)))
    wave.addCurve(to: CGPoint(x: centre.x + innerRadius, y: waterLine),
                  control1: CGPoint(x: centre.x + innerRadius * 0.45, y: waterLine + s(34)),
                  control2: CGPoint(x: centre.x + innerRadius * 0.55, y: waterLine - s(34)))
    wave.addLine(to: CGPoint(x: centre.x + innerRadius, y: centre.y - innerRadius))
    wave.addLine(to: CGPoint(x: centre.x - innerRadius, y: centre.y - innerRadius))
    wave.closeSubpath()

    context.addPath(wave)
    context.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [waterTop, waterBottom] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: waterLine),
                                   end: CGPoint(x: 0, y: centre.y - innerRadius),
                                   options: [])
    }
    context.restoreGState()

    // The brass ring.
    context.saveGState()
    context.setStrokeColor(brass)
    context.setLineWidth(ringWidth)
    context.addEllipse(in: CGRect(x: centre.x - outerRadius + ringWidth / 2,
                                  y: centre.y - outerRadius + ringWidth / 2,
                                  width: (outerRadius - ringWidth / 2) * 2,
                                  height: (outerRadius - ringWidth / 2) * 2))
    context.strokePath()
    context.restoreGState()

    // Four rivets, at the diagonals so they read as fittings rather than as a compass.
    // Dropped below 64px, where they turn into mud.
    if size >= 64 {
        context.setFillColor(brass)
        let rivetOrbit = outerRadius + s(52)
        for degrees in stride(from: 45.0, to: 360.0, by: 90.0) {
            let radians = degrees * .pi / 180
            context.fillEllipse(in: CGRect(
                x: centre.x + cos(radians) * rivetOrbit - s(17),
                y: centre.y + sin(radians) * rivetOrbit - s(17),
                width: s(34), height: s(34)))
        }
    }
}

func render(size: Int) -> Data? {
    let dimension = CGFloat(size)
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    drawIcon(size: dimension, into: context)
    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: dimension, height: dimension)
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Output

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// (pixel size, filename) for every entry macOS expects in an iconset.
let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (pixels, name) in variants {
    guard let data = render(size: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}

print("wrote \(variants.count) images to \(outputDirectory.path)")
