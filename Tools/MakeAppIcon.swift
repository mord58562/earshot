#!/usr/bin/env swift
// Generates Resources/AppIcon.icns at build time.
//
// Concept: "earshot" — the distance within which a sound carries.
//
//   - Off-axis origin point (the "shot") low-left.
//   - Concentric arcs expanding outward — soundwaves leaving the origin.
//   - The outermost arc is bent by an EQ peak: the precise listener-side
//     shaping the rest of the app does.
//   - Tahoe-flavour gradient: indigo → magenta → cyan.
//
// Usage: swift Tools/MakeAppIcon.swift <output.icns>

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    print("usage: MakeAppIcon.swift <output.icns>")
    exit(1)
}
let outIcns = URL(fileURLWithPath: CommandLine.arguments[1])

let sizes: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2)
]

func render(pixelSize: Int) -> NSImage {
    let size = NSSize(width: pixelSize, height: pixelSize)
    return NSImage(size: size, flipped: false) { rect in
        drawIcon(in: rect)
        return true
    }
}

func drawIcon(in rect: NSRect) {
    let s = rect.width
    let cornerRadius = s * 0.225

    // Rounded-square mask.
    let mask = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSGraphicsContext.current?.saveGraphicsState()
    mask.addClip()

    // Two-stop gradient diagonal — cleaner than the four-stop multi-hue
    // rainbow the earlier version used, which read as noisy at small
    // icon sizes. Indigo top-left → cyan bottom-right is the same color
    // territory as the prior version, but with one transition instead of
    // four, which reads cleanly down to 16px.
    let bg = NSGradient(colors: [
        NSColor(red: 0.18, green: 0.12, blue: 0.55, alpha: 1.0),  // indigo
        NSColor(red: 0.30, green: 0.65, blue: 0.92, alpha: 1.0)   // sky blue
    ])
    bg?.draw(in: rect, angle: -45)

    // Top-edge highlight gives the rounded square a sense of light from
    // above without the heavy "glossy" look earlier macOS used.
    if let highlight = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.18),
        NSColor(white: 1.0, alpha: 0.0)
    ]) {
        highlight.draw(in: NSRect(x: 0, y: s * 0.55, width: s, height: s * 0.45),
                       angle: -90)
    }

    // The glyph: lowercase "e" whose crossbar is a soundwave. Proportions
    // match the SwiftUI EQGlyph in the popover header (radius = 0.40·s,
    // wave amplitude = 0.28·radius) so the in-app logo and the dock icon
    // read as the same mark. Stroke is light enough (5.5% of canvas) that
    // it doesn't go chunky at large sizes.
    let cx = rect.midX
    let cy = rect.midY
    let radius = s * 0.40
    let strokeWidth = s * 0.055

    if let ctx = NSGraphicsContext.current {
        ctx.saveGraphicsState()

        // Outer ring: 330° arc starting at the +x axis. The 30° wedge at
        // the lower right is the open mouth of the "e". Polyline rather
        // than NSBezierPath.appendArc - the SwiftUI EQGlyph also draws as
        // a polyline, and matching the construction means the two glyphs
        // are visually identical at any resolution.
        let ring = NSBezierPath()
        let n = 96
        let startDeg: CGFloat = 0
        let sweepDeg: CGFloat = 330
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let rad = (startDeg + sweepDeg * t) * .pi / 180
            let x = cx + cos(rad) * radius
            let y = cy + sin(rad) * radius   // NSImage y-up
            if i == 0 { ring.move(to: NSPoint(x: x, y: y)) }
            else { ring.line(to: NSPoint(x: x, y: y)) }
        }
        ring.lineWidth = strokeWidth
        ring.lineCapStyle = .round
        ring.lineJoinStyle = .round
        NSColor.white.setStroke()
        ring.stroke()

        // Crossbar soundwave: lands EXACTLY at the ring's right tip
        // (cx + radius, cy) with horizontal tangent on arrival, so the
        // wave merges into the ring cleanly. Geometry mirrors EQGlyph.
        let leftX = cx - radius
        let rightX = cx + radius
        let amp = radius * 0.28
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: leftX, y: cy))
        // Trough (note y-up coords: trough = lower y).
        wave.curve(to: NSPoint(x: cx, y: cy),
                   controlPoint1: NSPoint(x: leftX + radius * 0.30, y: cy - amp),
                   controlPoint2: NSPoint(x: cx - radius * 0.30, y: cy + amp))
        // Peak, with horizontal tangent on arrival at the ring's right tip.
        wave.curve(to: NSPoint(x: rightX, y: cy),
                   controlPoint1: NSPoint(x: cx + radius * 0.30, y: cy - amp),
                   controlPoint2: NSPoint(x: rightX - radius * 0.10, y: cy))
        wave.lineWidth = strokeWidth
        wave.lineCapStyle = .round
        wave.stroke()

        ctx.restoreGraphicsState()
    }

    NSGraphicsContext.current?.restoreGraphicsState()
}

func arcPath(centerX: CGFloat, centerY: CGFloat, radius: CGFloat,
             startDegrees: CGFloat, endDegrees: CGFloat,
             in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let n = 80
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)
        let degrees = startDegrees + t * (endDegrees - startDegrees)
        let radians = degrees * .pi / 180
        let x = centerX + cos(radians) * radius
        let y = centerY + sin(radians) * radius
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
        else { path.line(to: NSPoint(x: x, y: y)) }
    }
    return path
}

/// Arc with two Gaussian deformations along its perimeter — peak (outward)
/// and dip (inward). Mimics the shape of a shaped EQ frequency response,
/// rotated onto a circular path.
func warpedArcPath(centerX: CGFloat, centerY: CGFloat, radius: CGFloat,
                   startDegrees: CGFloat, endDegrees: CGFloat,
                   peakDegrees: CGFloat, peakBoost: CGFloat,
                   dipDegrees: CGFloat, dipDepth: CGFloat,
                   in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let n = 220
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)
        let degrees = startDegrees + t * (endDegrees - startDegrees)
        let radians = degrees * .pi / 180

        // Two Gaussians: outward bump near peakDegrees, inward dip near dipDegrees.
        let peakWidth: CGFloat = 14
        let dipWidth: CGFloat = 18
        let peakOffset = peakBoost * exp(-pow((degrees - peakDegrees) / peakWidth, 2))
        let dipOffset  = -dipDepth * exp(-pow((degrees - dipDegrees) / dipWidth, 2))
        let r = radius + peakOffset + dipOffset

        let x = centerX + cos(radians) * r
        let y = centerY + sin(radians) * r
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
        else { path.line(to: NSPoint(x: x, y: y)) }
    }
    return path
}

func png(image: NSImage, size: Int) -> Data? {
    let pixels = size
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("EarshotIcon-\(UUID().uuidString).iconset")
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

for s in sizes {
    let pixels = s.pt * s.scale
    let img = render(pixelSize: pixels)
    guard let data = png(image: img, size: pixels) else { continue }
    let suffix = s.scale == 1 ? "" : "@2x"
    let name = "icon_\(s.pt)x\(s.pt)\(suffix).png"
    try? data.write(to: tmpDir.appendingPathComponent(name))
}

let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["-c", "icns", "-o", outIcns.path, tmpDir.path]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: tmpDir)

if proc.terminationStatus == 0 {
    print("Wrote \(outIcns.path)")
} else {
    fputs("iconutil failed (\(proc.terminationStatus))\n", stderr)
    exit(1)
}
