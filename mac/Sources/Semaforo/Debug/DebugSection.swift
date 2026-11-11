import SwiftUI

/// Shown at the bottom of the menu in debug mode.
struct DebugSection: View {
    @Environment(BoardModel.self) private var model
    @Bindable var debug: DebugController

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Debug", systemImage: "ladybug.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text("seen \(model.lastSeenAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("Scenario", selection: Binding(get: { debug.scenario }, set: { debug.select($0) })) {
                ForEach(DebugScenario.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            LazyVGrid(columns: columns, spacing: 6) {
                button("Start a run", "play.fill") { debug.startRun() }
                button("Finish: pass", "checkmark") { debug.finishRuns(success: true) }
                button("Finish: fail", "xmark") { debug.finishRuns(success: false) }
                button("Add 1 failure", "exclamationmark.triangle") { debug.addFailures(1) }
                button("Add 4 failures", "exclamationmark.3") { debug.addFailures(4) }
                button("Test notification", "bell") { debug.testNotification() }
                button("Forget seen", "eye.slash") { debug.forgetSeen() }
                button("Clear debug runs", "trash") { debug.clearInjected() }
            }

            if let status = debug.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func button(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
