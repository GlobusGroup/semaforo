import SwiftUI

/// Bell that watches or unwatches one repo (failure notifications). Only shown when Settings is on
/// "Watched repositories"; in the other modes every repo (or none) notifies, so there is nothing to pick.
struct NotifyBell: View {
    @Environment(BoardModel.self) private var model
    var repoFullName: String

    var body: some View {
        if model.notifyScope == .watched {
            let on = model.notifies(repoFullName)
            Button {
                model.setNotifies(!on, for: repoFullName)
            } label: {
                // bell.fill and bell.slash have different sizes; a fixed frame stops the card header
                // (and everything under it) from shifting when you toggle.
                Image(systemName: on ? "bell.fill" : "bell.slash")
                    .frame(width: 16, height: 16)
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                    .accessibilityLabel(on ? "Watching" : "Not watching")
            }
            .buttonStyle(.borderless)
            .frame(width: 18, height: 18)
            .help(on ? "Stop watching \(repoFullName)" : "Watch \(repoFullName): notify about its failures")
        }
    }
}

/// Context-menu item for the same choice.
struct NotifyMenuToggle: View {
    @Environment(BoardModel.self) private var model
    var repoFullName: String

    var body: some View {
        if model.notifyScope == .watched {
            Toggle("Watch", isOn: Binding(
                get: { model.notifies(repoFullName) },
                set: { model.setNotifies($0, for: repoFullName) }
            ))
        }
    }
}
