import SwiftUI

extension Signal {
    var color: Color {
        switch self {
        case .running: .blue
        case .queued: .orange
        case .success: .green
        case .failure: .red
        case .cancelled, .neutral: .gray
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
                PhaseAnimator([false, true]) { dim in
                    dot.opacity(dim ? 0.35 : 1)
                } animation: { _ in .easeInOut(duration: 0.9) }
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
