import Cocoa

/// Menubar glyph for Earshot: lowercase "e" whose crossbar is a sound
/// wave. The "e" reads as Earshot; the wave inside it is the audio.
/// Template image so AppKit tints it for light/dark mode.
///
/// The ring is drawn as a polyline rather than via SwiftUI's `addArc`
/// to avoid the angle-direction conventions in `Path.addArc` that
/// silently produce a spiral when the start/end angles cross zero.
enum MenubarGlyph {

    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()

            let cx: CGFloat = 9
            let cy: CGFloat = 9
            let radius: CGFloat = 6.0
            let strokeWidth: CGFloat = 1.7

            // Outer ring: 330° arc starting at the +x axis (3 o'clock),
            // sweeping counterclockwise (math convention) up, left, down,
            // and stopping just before completing the circle. The leftover
            // 30° wedge at the lower right is the open mouth of the "e".
            // NSImage(flipped: false) means y-up, so this draws visually
            // counterclockwise in screen coords too.
            let ring = NSBezierPath()
            let n = 96
            let startDeg: CGFloat = 0
            let sweepDeg: CGFloat = 330
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n)
                let rad = (startDeg + sweepDeg * t) * .pi / 180
                let x = cx + cos(rad) * radius
                let y = cy + sin(rad) * radius
                if i == 0 { ring.move(to: NSPoint(x: x, y: y)) }
                else { ring.line(to: NSPoint(x: x, y: y)) }
            }
            ring.lineWidth = strokeWidth
            ring.lineCapStyle = .round
            ring.lineJoinStyle = .round
            ring.stroke()

            // Crossbar soundwave: lands EXACTLY at the ring's right tip
            // (cx + radius, cy) with horizontal tangent on arrival, so
            // there's no visible ledge where wave meets ring.
            let leftX = cx - radius
            let rightX = cx + radius
            let amp: CGFloat = 1.7
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: leftX, y: cy))
            wave.curve(to: NSPoint(x: cx, y: cy),
                       controlPoint1: NSPoint(x: leftX + 1.6, y: cy - amp * 1.4),
                       controlPoint2: NSPoint(x: cx - 1.6, y: cy + amp * 1.4))
            // control2 sits at (rightX - small, cy) so the curve's tangent
            // is horizontal as it arrives at the ring.
            wave.curve(to: NSPoint(x: rightX, y: cy),
                       controlPoint1: NSPoint(x: cx + 1.6, y: cy - amp * 1.4),
                       controlPoint2: NSPoint(x: rightX - 0.6, y: cy))
            wave.lineWidth = strokeWidth
            wave.lineCapStyle = .round
            wave.stroke()

            return true
        }
        img.isTemplate = true
        return img
    }
}
