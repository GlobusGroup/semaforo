import SwiftUI

/// Bell that turns failure notifications on or off for one repo. Only shown when Settings is on
/// "Selected repositories"; in the other modes every repo (or none) notifies, so there is nothing to pick.
struct NotifyBell: View {
    @Environment(BoardModel.self) private var model
    var repoFullName: String

    var body: some View {
        if model.notifyScope == .selected {
            let on = model.notifies(repoFullName)
            Button {
                model.setNotifies(!on, for: repoFullName)
            } label: {
                Label(on ? "Notifications On" : "Notifications Off", systemImage: on ? "bell.fill" : "bell.slash")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(on ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(on ? "Stop notifying about failures in \(repoFullName)" : "Notify about failures in \(repoFullName)")
        }
    }
}

/// Context-menu item for the same choice.
struct NotifyMenuToggle: View {
    @Environment(BoardModel.self) private var model
    var repoFullName: String

    var body: some View {
        if model.notifyScope == .selected {
            Toggle("Notify About Failures", isOn: Binding(
                get: { model.notifies(repoFullName) },
                set: { model.setNotifies($0, for: repoFullName) }
            ))
        }
    }
}
