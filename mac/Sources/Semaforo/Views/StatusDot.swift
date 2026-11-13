import SwiftUI

extension Signal {
    var color: Color {
        // GitHub's palette, so dots agree with GitHubStatusIcon.
        switch self {
        case .running, .queued: GitHubColor.pending
        case .success: GitHubColor.success
        case .failure: GitHubColor.failure
        case .cancelled, .neutral: GitHubColor.neutral
        }
    }
}

/// Small coloured circle for a run's signal; pulses while running.
struct StatusDot: View {
    var signal: Signal
    var size: CGFloat = 8

    var body: some View {
        Group {
            if signal == .running {
                PulsingDot(color: GitHubColor.nsPending)
            } else {
                dot
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(signal.label)
    }

    private var dot: some View {
        Circle().fill(signal.color)
    }
}

/// Dot + label, e.g. "● Failed".
struct StatusLabel: View {
    var signal: Signal

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(signal: signal)
            Text(signal.label)
        }
    }
}

/// The running dot's pulse, done with Core Animation. A SwiftUI `PhaseAnimator` here re-rendered
/// the whole sidebar on every display frame while anything was running (constant CPU use).
private struct PulsingDot: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> PulsingDotView { PulsingDotView() }
    func updateNSView(_ view: PulsingDotView, context: Context) { view.color = color }
}

private final class PulsingDotView: NSView {
    var color: NSColor = .systemOrange { didSet { needsLayout = true } }
    private let dot = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        dot.frame = bounds
        dot.path = CGPath(ellipseIn: bounds, transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance { dot.fillColor = color.cgColor }
        startPulsing()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startPulsing()
    }

    private func startPulsing() {
        guard window != nil, dot.animation(forKey: "pulse") == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        dot.add(pulse, forKey: "pulse")
    }
}
