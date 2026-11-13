import AppKit
import SwiftUI

/// A run's status drawn the way github.com draws it in run lists: filled green check, red cross,
/// amber spinning ring while in progress, amber dot when queued, grey slash when stopped/skipped.
struct GitHubStatusIcon: View {
    var run: WorkflowRun
    var size: CGFloat = 16

    var body: some View {
        icon
            .frame(width: size, height: size)
            .help(run.signal.label)
            .accessibilityLabel(run.signal.label)
    }

    @ViewBuilder private var icon: some View {
        switch run.signal {
        case .success:
            filled("checkmark.circle.fill", GitHubColor.success)
        case .failure:
            filled("xmark.circle.fill", GitHubColor.failure)
        case .running:
            Spinner(color: GitHubColor.nsPending, lineWidth: size * 0.14)
        case .queued:
            ZStack {
                Circle().strokeBorder(GitHubColor.pending, lineWidth: size * 0.12)
                Circle().fill(GitHubColor.pending).padding(size * 0.31)
            }
        case .cancelled:
            Image(systemName: run.conclusion == "skipped" ? "slash.circle" : "slash.circle.fill")
                .resizable()
                .foregroundStyle(GitHubColor.neutral)
        case .neutral:
            Circle().strokeBorder(GitHubColor.neutral, lineWidth: size * 0.12)
        }
    }

    private func filled(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
    }
}

/// GitHub's in-progress indicator: a ring with a darker arc that spins.
///
/// Drawn with Core Animation, not a SwiftUI `repeatForever` animation: that one re-renders the
/// whole hosting view (and relayouts the table around it) on every display frame, which kept the
/// app at ~25% CPU whenever a run was in progress. A layer rotation runs in the window server.
private struct Spinner: NSViewRepresentable {
    var color: NSColor
    var lineWidth: CGFloat

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.color = color
        view.lineWidth = lineWidth
    }
}

private final class SpinnerView: NSView {
    var color: NSColor = .systemOrange { didSet { needsLayout = true } }
    var lineWidth: CGFloat = 2 { didSet { needsLayout = true } }

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        arc.strokeEnd = 0.3
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset = lineWidth
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGPath(ellipseIn: rect, transform: nil)
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = path
            shape.lineWidth = lineWidth
        }
        updateColors()
        startSpinning()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startSpinning()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = color.withAlphaComponent(0.3).cgColor
            arc.strokeColor = color.cgColor
        }
    }

    private func startSpinning() {
        // Rotate about the centre, not the layer's default bottom-left anchor.
        arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        guard window != nil, arc.animation(forKey: "spin") == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}

/// GitHub's Primer colours for run states, light and dark. `ns*` for AppKit drawing (menu bar).
enum GitHubColor {
    static let nsSuccess = dynamic(light: 0x1A7F37, dark: 0x3FB950)
    static let nsFailure = dynamic(light: 0xD1242F, dark: 0xF85149)
    static let nsPending = dynamic(light: 0xBF8700, dark: 0xD29922)
    static let nsNeutral = dynamic(light: 0x59636E, dark: 0x9198A1)

    static let success = Color(nsColor: nsSuccess)
    static let failure = Color(nsColor: nsFailure)
    static let pending = Color(nsColor: nsPending)
    static let neutral = Color(nsColor: nsNeutral)

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        }
    }
}
