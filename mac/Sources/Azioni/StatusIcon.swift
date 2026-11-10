import AppKit

/// The menu bar mark: a three-stage pipeline (■—■—●) whose last stage shows the board's state,
/// the way Docker's whale carries a small status badge.
enum StatusIcon {
    enum Badge: Sendable {
        /// Hollow ring: nothing running, nothing passed recently.
        case idle
        /// Green check: the latest finished run passed recently.
        case passed
        /// Amber in-progress ring: runs in progress.
        case running
        /// Red, cross: new failures.
        case failed
        /// Grey, exclamation mark, whole mark dimmed: can't reach GitHub.
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

        // Final stage, in GitHub's colours and shapes (see GitHubStatusIcon).
        let circle = NSRect(x: x, y: midY - final / 2, width: final, height: final)
        switch badge {
        case .idle:
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1.25, dy: 1.25))
            ring.lineWidth = 1.5
            ring.stroke()
        case .running:
            // GitHub's in-progress ring: faint track plus a solid arc.
            let r = circle.insetBy(dx: 1.4, dy: 1.4)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = 2.2
            GitHubColor.nsPending.withAlphaComponent(0.45).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                          startAngle: 90, endAngle: -120, clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            GitHubColor.nsPending.setStroke()
            arc.stroke()
        case .passed:
            badgeDisc(circle, GitHubColor.nsSuccess, glyph: "checkmark")
        case .failed:
            badgeDisc(circle, GitHubColor.nsFailure, glyph: "xmark")
        case .problem:
            badgeDisc(circle, GitHubColor.nsNeutral, glyph: "exclamationmark")
        }
    }

    private static func badgeDisc(_ circle: NSRect, _ fill: NSColor, glyph: String) {
        fill.setFill()
        NSBezierPath(ovalIn: circle).fill()
        let config = NSImage.SymbolConfiguration(pointSize: glyph == "xmark" ? 6 : 7, weight: .black)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let r = NSRect(x: circle.midX - symbol.size.width / 2, y: circle.midY - symbol.size.height / 2,
                       width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: r)
    }

    /// An image that redraws in whatever appearance it is drawn in (light or dark menu bar).
    static func image(_ badge: Badge) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(badge, ink: .labelColor, in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Semaforo"
        return image
    }
}
