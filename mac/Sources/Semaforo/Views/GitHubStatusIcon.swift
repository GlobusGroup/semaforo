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
            Spinner(color: GitHubColor.pending, lineWidth: size * 0.14)
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
private struct Spinner: View {
    var color: Color
    var lineWidth: CGFloat
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.3), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .padding(lineWidth / 2)
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spinning = true }
        }
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
