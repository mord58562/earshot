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

    // Tahoe-style gradient backdrop.
    let bg = NSGradient(colors: [
        NSColor(red: 0.10, green: 0.06, blue: 0.30, alpha: 1.0),  // deep indigo
        NSColor(red: 0.42, green: 0.10, blue: 0.55, alpha: 1.0),  // royal violet
        NSColor(red: 0.20, green: 0.55, blue: 0.85, alpha: 1.0),  // electric blue
        NSColor(red: 0.10, green: 0.85, blue: 0.85, alpha: 1.0)   // cyan glow
    ])
    bg?.draw(in: rect, angle: 120)

    // Soft top-side highlight to give the rounded shape some depth.
    if let highlight = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.22),
        NSColor(white: 1.0, alpha: 0.0)
    ]) {
        highlight.draw(in: NSRect(x: 0, y: s * 0.5, width: s, height: s * 0.5),
                       angle: -90)
    }

    // The glyph: lowercase "e" with a soundwave crossbar, matching the
    // menubar template image scaled up. Rendered in white with a very
    // subtle drop shadow so it reads on the gradient at any size.
    let cx = rect.midX
    let cy = rect.midY
    let radius = s * 0.30
    let strokeWidth = s * 0.060

    if let ctx = NSGraphicsContext.current {
        ctx.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.30)
        shadow.shadowBlurRadius = s * 0.012
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
        shadow.set()

        // Outer ring: 330° arc from 3 o'clock sweeping counter-clockwise,
        // leaving a 30° opening at the lower right — the mouth of the e.
        // Built with NSBezierPath.appendArc (true cubic-bezier arc, four
        // segments per quadrant) instead of a polyline; with strokes this
        // thick the polyline approximation read as faceted.
        let ring = NSBezierPath()
        ring.appendArc(withCenter: NSPoint(x: cx, y: cy),
                       radius: radius,
                       startAngle: 0,
                       endAngle: 330)
        ring.lineWidth = strokeWidth
        ring.lineCapStyle = .round
        ring.lineJoinStyle = .round
        NSColor.white.setStroke()
        ring.stroke()

        // Crossbar soundwave: one full sine cycle across the diameter —
        // trough on the left half, peak on the right. Each half is a
        // cubic-bezier approximation of half a sine: control handles at
        // 36% / 64% of the half-period in x, ±(4/3)·amplitude in y, which
        // makes a symmetric cubic whose midpoint sits exactly at ±amp.
        // The two halves share the same tangent at (cx, cy) so the join
        // is C1-smooth — no kink under the heavy stroke.
        let leftX = cx - radius + strokeWidth * 0.25
        let rightX = cx + radius - strokeWidth * 0.25
        let halfWave = (rightX - leftX) / 2
        let amp = radius * 0.30
        let handleY = amp * (4.0 / 3.0)
        let handleDX = halfWave * 0.36
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: leftX, y: cy))
        // Trough (down in y-up coords).
        wave.curve(to: NSPoint(x: cx, y: cy),
                   controlPoint1: NSPoint(x: leftX + handleDX, y: cy - handleY),
                   controlPoint2: NSPoint(x: cx - handleDX,    y: cy - handleY))
        // Peak (up).
        wave.curve(to: NSPoint(x: rightX, y: cy),
                   controlPoint1: NSPoint(x: cx + handleDX,    y: cy + handleY),
                   controlPoint2: NSPoint(x: rightX - handleDX, y: cy + handleY))
        wave.lineWidth = strokeWidth
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round
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
