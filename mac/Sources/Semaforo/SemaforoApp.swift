import AppKit
import SwiftUI

@main
struct SemaforoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The projects window is an AppKit-managed NSWindow (ProjectsWindowController) rather than a
        // SwiftUI `Window` scene: on macOS 14 a `Window` scene opens itself at launch (the
        // `.defaultLaunchBehavior(.suppressed)` fix is macOS 15+), and `openWindow` is unreliable
        // from views hosted outside a scene, like the status item's popover. A body with only a
        // never-inserted MenuBarExtra opens nothing at launch (a bare `Settings` scene does open its
        // window when launched unbundled) and still gives SwiftUI's standard main menu.
        MenuBarExtra("Semaforo", systemImage: "checkmark.circle", isInserted: .constant(false)) {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: BoardModel?
    private var statusItem: StatusItemController?
    private var projectsWindow: ProjectsWindowController?
    private var debug: DebugController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement covers the bundled app; this covers `swift run`.
        NSApp.setActivationPolicy(.accessory)

        let notifier = Notifier()
        notifier.requestAuthorization()
        let model: BoardModel
        if DebugController.isEnabled {
            // e.g. `open Semaforo.app --args -debug YES -debugScenario failures`
            let scenario = DebugController.launchScenario
            let source = DebugRunSource(live: RunStore(), scenario: scenario)
            // Debug scenarios are about seeing failures, so every repo counts unless Settings says otherwise.
            model = BoardModel(store: source, notifier: notifier, defaultNotifyScope: .all)
            debug = DebugController(source: source, model: model, notifier: notifier, scenario: scenario)
        } else {
            model = BoardModel(notifier: notifier)
        }
        let projectsWindow = ProjectsWindowController(model: model)
        self.model = model
        self.projectsWindow = projectsWindow
        statusItem = StatusItemController(model: model, debug: debug) { [weak projectsWindow] in
            projectsWindow?.show()
        }
        model.start()
        // Creating it starts Sparkle, which then checks for updates on its own schedule.
        _ = AppUpdater.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        projectsWindow?.show()
        return false
    }
}
