import ServiceManagement
import SwiftUI

/// Settings sheet in the projects window (toolbar gear, ⌘,): login item, notifications, refresh, API budget,
/// updates.
struct SettingsView: View {
    @Environment(BoardModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let updater = AppUpdater.shared

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

                Section("Notifications") {
                    @Bindable var model = model
                    Picker("Notify about failures in", selection: $model.notifyScope) {
                        ForEach(NotificationScope.allCases) { Text($0.label).tag($0) }
                    }
                    if model.notifyScope == .selected {
                        if model.notifyRepos.isEmpty {
                            Text("None yet. Use the bell on a repository card, or right-click a repository in the sidebar.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(model.notifyRepos.sorted(), id: \.self) { name in
                                HStack {
                                    Text(name)
                                    Spacer()
                                    Button {
                                        model.setNotifies(false, for: name)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Stop notifying about \(name)")
                                }
                            }
                        }
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

                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updater.checksAutomatically },
                        set: { updater.checksAutomatically = $0 }
                    ))
                    .disabled(!updater.isActive)
                    HStack {
                        Text(updater.isActive
                            ? "Semaforo \(updater.version)"
                            : "Semaforo \(updater.version) · updates are off in local builds")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .disabled(!updater.isActive || !updater.canCheckForUpdates)
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
            loginNote = "Approve Semaforo in System Settings › General › Login Items."
        }
    }
}
