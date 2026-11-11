import SwiftUI

/// Content of the status item's popover.
struct MenuView: View {
    @Environment(BoardModel.self) private var model
    @Environment(DebugController.self) private var debug: DebugController?
    var session: MenuSession
    var dismiss: @MainActor () -> Void
    var openWindow: @MainActor () -> Void

    private static let maxFailures = 6
    private static let maxRunning = 8
    private static let maxRecent = 8
    static let width: CGFloat = 520

    var body: some View {
        let failures = model.menuFailures(snapshot: session.snapshotFailures)
        let running = model.liveRuns
        let shown = Set(failures.map(\.id)).union(running.map(\.id))
        let recent = Array(model.recentRuns.filter { !shown.contains($0.id) }.prefix(Self.maxRecent))

        VStack(alignment: .leading, spacing: 0) {
            header(running: running.count, failures: failures.count)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if let problem = model.problem {
                ProblemBanner(message: problem)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                if !failures.isEmpty {
                    section("New failures", runs: failures, limit: Self.maxFailures, highlighted: true)
                }
                if !running.isEmpty {
                    section("Running now", runs: running, limit: Self.maxRunning)
                }
                if !recent.isEmpty {
                    section("Recent", runs: recent, limit: Self.maxRecent)
                }
                if failures.isEmpty && running.isEmpty && recent.isEmpty {
                    Text(model.fetchedAt == nil ? "Loading workflow runs…" : "No workflow runs in the last 24 hours")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            }
            .padding(.vertical, 6)

            if let debug {
                Divider()
                DebugSection(debug: debug)
            }

            Divider()

            MenuFooter(dismiss: dismiss, openWindow: openWindow)
                .padding(.vertical, 6)
        }
        .frame(width: Self.width)
    }

    private func header(running: Int, failures: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(summary(running: running, failures: failures))
                .font(.headline)
            Spacer()
            if let fetchedAt = model.fetchedAt {
                Text("Updated \(fetchedAt.formatted(.dateTime.hour().minute().second()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func summary(running: Int, failures: Int) -> String {
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if failures > 0 { parts.append("\(failures) new failure\(failures == 1 ? "" : "s")") }
        if parts.isEmpty { return model.fetchedAt == nil ? "Semaforo" : "All quiet" }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func section(_ title: String, runs: [WorkflowRun], limit: Int, highlighted: Bool = false) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(highlighted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)
        ForEach(runs.prefix(limit)) { run in
            Button {
                run.open()
                dismiss()
            } label: {
                RunRow(run: run, highlighted: highlighted)
            }
            .buttonStyle(MenuRowButtonStyle(tint: highlighted ? .red.opacity(0.08) : nil))
            .help(run.htmlURL)
        }
        if runs.count > limit {
            Button("\(runs.count - limit) more…", action: openWindow)
                .buttonStyle(MenuRowButtonStyle())
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

private struct ProblemBanner: View {
    var message: String

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.orange)
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Just the two things you do from the menu; refresh, login item and API budget live in the
/// window's Settings.
private struct MenuFooter: View {
    var dismiss: @MainActor () -> Void
    var openWindow: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: openWindow) {
                footerLabel("Open Semaforo Window", systemImage: "macwindow")
            }
            .buttonStyle(MenuRowButtonStyle())
            .keyboardShortcut("o")

            Button {
                NSApp.terminate(nil)
            } label: {
                footerLabel("Quit Semaforo", systemImage: "xmark.circle")
            }
            .buttonStyle(MenuRowButtonStyle())
            .keyboardShortcut("q")
        }
    }

    private func footerLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(MenuLabelStyle())
    }
}

/// Icon column with a fixed width so footer titles line up like a native menu.
private struct MenuLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 16)
            configuration.title
        }
    }
}

/// Full-width row with a native-menu-like hover highlight.
struct MenuRowButtonStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, tint: tint)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(fill)
                }
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.6)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return .primary.opacity(0.15) }
            if hovering && isEnabled { return .primary.opacity(0.08) }
            return tint ?? .clear
        }
    }
}
