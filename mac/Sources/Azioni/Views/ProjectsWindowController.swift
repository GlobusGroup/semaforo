import AppKit
import SwiftUI

/// Owns the single projects window. While it is open the app uses the `.regular` activation policy
/// (Dock icon, Cmd-Tab); closing it goes back to `.accessory` (menu bar only).
@MainActor
final class ProjectsWindowController: NSObject, NSWindowDelegate {
    private let model: BoardModel
    private var window: NSWindow?

    init(model: BoardModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: ProjectsView().environment(model))
        host.sceneBridgingOptions = .all
        let window = NSWindow(contentViewController: host)
        window.title = "Azioni"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 980, height: 600))
        window.contentMinSize = NSSize(width: 720, height: 400)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ProjectsWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
