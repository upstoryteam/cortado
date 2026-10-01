import AppKit

/// The menu bar icon: a small cortado cup that fills with memory pressure,
/// and beside it a mark for keep-awake.
///
/// A template image is one colour throughout, so this isn't one. It is drawn in
/// the colours of whichever menu bar it is in, each time it is drawn.
nonisolated enum StatusIcon {
    /// What the mark beside the gauge says.
    enum Awake: Sendable, Equatable {
        case off
        /// Off, and set to switch on when an agent starts working. Drawn as a ring.
        case waiting
        /// Drawn as a dot in `awakeColor`.
        case on
    }

    /// The colour for on, so the dot here and the word in the panel agree.
    static var awakeColor: NSColor { .controlAccentColor }

    /// The same with or without the mark. A menu bar item that changed width
    /// would shift its neighbours, and the open panel with it, on every switch.
    static let size = NSSize(width: 23, height: 18)

    static func image(fraction: Double, level: PressureLevel, awake: Awake) -> NSImage {
        return NSImage(size: size, flipped: false) { _ in
            (tint(for: level) ?? .labelColor).set()

            // A cortado cup from the side: tapered, with a handle, on its saucer.
            for line in [cup(inset: 0), handle, saucer] {
                line.lineWidth = 1.25
                line.lineCapStyle = .round
                line.lineJoinStyle = .round
                line.stroke()
            }

            // The coffee, a little inside the cup, up to the brim when memory is full.
            let inset = 1.65
            let height = max(1.25, (rim - foot - 2 * inset) * min(1, max(0, fraction)))
            NSGraphicsContext.saveGraphicsState()
            cup(inset: inset).addClip()
            NSRect(x: 0, y: foot + inset, width: 13, height: height).fill()
            NSGraphicsContext.restoreGraphicsState()

            let mark = NSRect(x: 16, y: 6, width: 6, height: 6)
            switch awake {
            case .off:
                break
            case .waiting:
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(ovalIn: mark.insetBy(dx: 0.625, dy: 0.625))
                ring.lineWidth = 1.25
                ring.stroke()
            case .on:
                awakeColor.setFill()
                NSBezierPath(ovalIn: mark).fill()
            }
            return true
        }
    }

    private static let centre = 6.5, rim = 15.375, foot = 4.625

    /// Half as wide as the cup at a height: 3.4 at its foot, 5.4 at its rim.
    private static func half(_ y: Double) -> Double { 3.4 + 2 * (y - foot) / (rim - foot) }

    /// The cup's outline, or the shape `inset` inside it.
    private static func cup(inset: Double) -> NSBezierPath {
        let top = rim - inset, bottom = foot + inset
        let wide = half(top) - inset, narrow = half(bottom) - inset
        let corner = max(0.75, 2.4 - inset)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: centre - wide, y: top))
        path.appendArc(
            from: NSPoint(x: centre - narrow, y: bottom), to: NSPoint(x: centre + narrow, y: bottom), radius: corner
        )
        path.appendArc(
            from: NSPoint(x: centre + narrow, y: bottom), to: NSPoint(x: centre + wide, y: top), radius: corner
        )
        path.line(to: NSPoint(x: centre + wide, y: top))
        path.close()
        return path
    }

    private static var handle: NSBezierPath {
        let high = 13.25, low = 8.25, reach = 3.4
        let path = NSBezierPath()
        path.move(to: NSPoint(x: centre + half(high), y: high))
        path.curve(
            to: NSPoint(x: centre + half(low), y: low),
            controlPoint1: NSPoint(x: centre + half(high) + reach, y: high + 0.5),
            controlPoint2: NSPoint(x: centre + half(high) + reach, y: low - 0.3)
        )
        return path
    }

    private static var saucer: NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: centre - 5.8, y: 2.125))
        path.line(to: NSPoint(x: centre + 5.8, y: 2.125))
        return path
    }

    /// Nil leaves the cup in the menu bar's own colour.
    static func tint(for level: PressureLevel) -> NSColor? {
        switch level {
        case .normal: nil
        case .warning: .systemYellow
        case .critical: .systemRed
        }
    }

    static func description(level: PressureLevel, awake: Awake) -> String {
        let memory = "Memory pressure \(level.label.lowercased())"
        return switch awake {
        case .off: memory
        case .waiting: memory + ". Keep awake is waiting for an agent"
        case .on: memory + ". Keep awake is on"
        }
    }
}
