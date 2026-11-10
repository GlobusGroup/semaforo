import AppKit

/// The menu bar mark: a three-stage pipeline (■—■—●) whose last stage shows the board's state,
/// the way Docker's whale carries a small status badge.
enum StatusIcon {
    enum Badge: Sendable {
        /// Hollow ring: nothing running, nothing passed recently.
        case idle
        /// Green check: the latest finished run passed recently.
        case passed
        /// Blue, play glyph: runs in progress.
        case running
        /// Red, exclamation mark: new failures.
        case failed
        /// Orange, exclamation mark, whole mark dimmed: can't reach GitHub.
        case problem
    }

    static let size = NSSize(width: 28, height: 16)

    /// `ink` is the colour of the stages (the menu bar's label colour for the current appearance).
    static func draw(_ badge: Badge, ink: NSColor, in rect: NSRect) {
        let stage: CGFloat = 5.5
        let gap: CGFloat = 3
        let final: CGFloat = 11
        let midY = rect.midY
        let inkColor = badge == .problem ? ink.withAlphaComponent(0.45) : ink

        // Stages and connectors.
        inkColor.setFill()
        inkColor.setStroke()
        var x = rect.minX
        for _ in 0..<2 {
            NSBezierPath(roundedRect: NSRect(x: x, y: midY - stage / 2, width: stage, height: stage),
                         xRadius: 1.4, yRadius: 1.4).fill()
            x += stage
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: midY))
            line.line(to: NSPoint(x: x + gap, y: midY))
            line.lineWidth = 1.5
            line.stroke()
            x += gap
        }

        // Final stage.
        let circle = NSRect(x: x, y: midY - final / 2, width: final, height: final)
        let (fill, glyph): (NSColor?, String?) = switch badge {
        case .idle: (nil, nil)
        case .passed: (.systemGreen, "checkmark")
        case .running: (.systemBlue, "play.fill")
        case .failed: (.systemRed, "exclamationmark")
        case .problem: (.systemOrange, "exclamationmark")
        }
        guard let fill, let glyph else {
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1.25, dy: 1.25))
            ring.lineWidth = 1.5
            ring.stroke()
            return
        }
        fill.setFill()
        NSBezierPath(ovalIn: circle).fill()
        let pointSize: CGFloat = glyph == "play.fill" ? 6 : 7
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .black)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            var r = NSRect(origin: .zero, size: symbol.size)
            r.origin = NSPoint(x: circle.midX - r.width / 2 + (glyph == "play.fill" ? 0.5 : 0),
                               y: circle.midY - r.height / 2)
            symbol.draw(in: r)
        }
    }

    /// An image that redraws in whatever appearance it is drawn in (light or dark menu bar).
    static func image(_ badge: Badge) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(badge, ink: .labelColor, in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Azioni"
        return image
    }
}
