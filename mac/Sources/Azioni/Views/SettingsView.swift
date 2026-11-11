import ServiceManagement
import SwiftUI

/// Settings sheet in the projects window (toolbar gear, ⌘,), laid out like System Settings: a sidebar
/// of panes (General, Notifications, GitHub, Updates) and the selected pane's form.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case notifications = "Notifications"
        case github = "GitHub"
        case updates = "Updates"

        var id: Self { self }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .notifications: "bell.badge"
            case .github: "arrow.triangle.2.circlepath"
            case .updates: "arrow.down.circle"
            }
        }
    }

    @Environment(BoardModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let updater = AppUpdater.shared

    @AppStorage("settingsPane") private var pane: Pane = .general
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(Pane.allCases, selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) { pane in
                    Label(pane.rawValue, systemImage: pane.icon).tag(pane)
                }
                .listStyle(.sidebar)
                .frame(width: 180)

                Divider()

                Form { content }
                    .formStyle(.grouped)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 420)
        .onAppear { refreshLoginStatus() }
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general: general
        case .notifications: notifications
        case .github: github
        case .updates: updates
        }
    }

    private var general: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
            if let loginNote {
                Text(loginNote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var notifications: some View {
        @Bindable var model = model
        Section {
            Picker("Notify about failures in", selection: $model.notifyScope) {
                ForEach(NotificationScope.allCases) { Text($0.label).tag($0) }
            }
        } footer: {
            Text("Also decides which failures count on the menu bar icon and in the menu's New failures list.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if model.notifyScope == .watched {
            Section("Watching") {
                if model.notifyRepos.isEmpty {
                    Text("You're not watching any repositories yet. Use the bell on a repository card, or right-click a repository in the sidebar and choose Watch.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.notifyRepos.sorted(), id: \.self) { name in
                        HStack {
                            Text(model.repoNaming.name(name))
                            Spacer()
                            Button {
                                model.setNotifies(false, for: name)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop watching \(name)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var github: some View {
        Section {
            LabeledContent("Last update") {
                if let fetched = model.fetchedAt {
                    RelativeTime(date: fetched)
                } else {
                    Text("Not yet")
                }
            }
            LabeledContent("API requests this hour") {
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
        }
        Section {
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

    private var updates: some View {
        Section {
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

    private var budget: String {
        guard let rate = model.sync?.rateLimit else { return "—" }
        return "\((rate.limit - rate.remaining).formatted()) / \(rate.limit.formatted()) used"
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
