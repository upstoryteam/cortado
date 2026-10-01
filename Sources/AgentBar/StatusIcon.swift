import AppKit

/// The menu bar icon: a small vertical gauge that fills with memory pressure,
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
    static let size = NSSize(width: 21, height: 18)

    static func image(fraction: Double, level: PressureLevel, awake: Awake) -> NSImage {
        return NSImage(size: size, flipped: false) { _ in
            (tint(for: level) ?? .labelColor).set()

            let body = NSRect(x: 2, y: 2, width: 9, height: 14)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1.25
            outline.stroke()

            let well = body.insetBy(dx: 2.25, dy: 2.25)
            let height = max(1.5, well.height * min(1, max(0, fraction)))
            let fill = NSRect(x: well.minX, y: well.minY, width: well.width, height: height)
            NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()

            let mark = NSRect(x: 14, y: 6, width: 6, height: 6)
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

    /// Nil leaves the gauge in the menu bar's own colour.
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
