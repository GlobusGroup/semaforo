import SwiftUI

@main
struct AzioniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Azioni", id: "projects") {
            Text("TODO(agent: ui)")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // TODO(agent: ui): own BoardModel + StatusItemController
}
