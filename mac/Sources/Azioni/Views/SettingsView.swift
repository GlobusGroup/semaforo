import ServiceManagement
import SwiftUI

/// Settings sheet in the projects window (toolbar gear, ⌘,): login item, refresh, API budget.
struct SettingsView: View {
    @Environment(BoardModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("General") {
                    Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                    if let loginNote {
                        Text(loginNote).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("GitHub") {
                    LabeledContent("Last update") {
                        if let fetched = model.fetchedAt {
                            RelativeTime(date: fetched)
                        } else {
                            Text("Not yet")
                        }
                    }
                    LabeledContent("API budget") {
                        Text(budget).monospacedDigit()
                    }
                    if let reset = model.sync?.rateLimit?.resetAt {
                        LabeledContent("Budget resets") {
                            Text(reset, format: .dateTime.hour().minute())
                        }
                    }
                    if let problem = model.problem {
                        LabeledContent("Problem") {
                            Text(problem).foregroundStyle(.orange)
                        }
                    }
                    HStack {
                        Spacer()
                        if model.isRefreshing { ProgressView().controlSize(.small) }
                        Button("Refresh Now") {
                            Task { await model.refresh() }
                        }
                        .disabled(model.isRefreshing)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .onAppear { refreshLoginStatus() }
    }

    private var budget: String {
        guard let rate = model.sync?.rateLimit else { return "—" }
        return "\(rate.remaining.formatted()) / \(rate.limit.formatted()) left"
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
            loginNote = nil
        } catch {
            loginNote = "Couldn't change the login item: \(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval {
            loginNote = "Approve Azioni in System Settings › General › Login Items."
        }
    }
}
