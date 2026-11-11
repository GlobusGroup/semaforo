import AppKit
import SwiftUI

/// What the open menu remembers: the failures that were unseen when it opened, so they stay
/// highlighted even though opening the menu marks them seen ("cleared next time").
@MainActor
@Observable
final class MenuSession {
    var snapshotFailures: [WorkflowRun] = []
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: BoardModel
    private let statusItem: NSStatusItem = {
        // New items land on the left of the extras, which on a full menu bar is under the notch,
        // where macOS hides them. Until the user ⌘-drags it somewhere, start near the clock.
        // (Position is points from the right edge; macOS reads it when the item is created.)
        let key = "NSStatusItem Preferred Position \(StatusItemController.autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(260.0, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = StatusItemController.autosaveName
        return item
    }()
    // Keeps its old name: it is the key macOS stores the icon's menu bar position under.
    private static let autosaveName = "AzioniStatusItem"
    private let popover = NSPopover()
    private let session = MenuSession()
    private let openProjects: @MainActor () -> Void
    private let debug: DebugController?

    init(model: BoardModel, debug: DebugController? = nil, openProjects: @escaping @MainActor () -> Void) {
        self.model = model
        self.debug = debug
        self.openProjects = openProjects
        super.init()


        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.delegate = self
        let menu = MenuView(
            session: session,
            dismiss: { [weak self] in self?.closePopover() },
            openWindow: { [weak self] in
                self?.closePopover()
                self?.openProjects()
            }
        )
        let host = NSHostingController(rootView: menu.environment(model).environment(debug))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        observe()
    }

    // MARK: Icon

    /// Re-arming observation loop: `withObservationTracking` fires once per change.
    private func observe() {
        withObservationTracking {
            render(model.iconState)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render(_ state: IconState) {
        guard let button = statusItem.button else { return }
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        button.appearsDisabled = false
        button.imagePosition = .imageLeading

        let count: (Int, NSColor) -> NSAttributedString = { n, color in
            NSAttributedString(string: " \(n)", attributes: [.font: font, .foregroundColor: color])
        }
        button.attributedTitle = NSAttributedString()
        switch state {
        case let .failures(unseen, running):
            button.image = StatusIcon.image(.failed)
            let title = NSMutableAttributedString(attributedString: count(unseen, GitHubColor.nsFailure))
            if running > 0 {
                title.append(NSAttributedString(
                    string: "  ◌\(running)",
                    attributes: [.font: font, .foregroundColor: GitHubColor.nsPending]
                ))
            }
            button.attributedTitle = title
            button.toolTip = "\(unseen) new failure\(unseen == 1 ? "" : "s")"
                + (running > 0 ? ", \(running) running" : "")
        case let .running(n):
            button.image = StatusIcon.image(.running)
            button.attributedTitle = count(n, .labelColor)
            button.toolTip = "\(n) running"
        case .problem:
            button.image = StatusIcon.image(.problem)
            button.toolTip = model.problem ?? "Semaforo can't reach GitHub"
        case .passed:
            button.image = StatusIcon.image(.passed)
            button.toolTip = "Semaforo: latest run passed"
        case .idle:
            button.image = StatusIcon.image(.idle)
            button.toolTip = "Semaforo: idle"
        }
        if button.attributedTitle.length == 0 { button.imagePosition = .imageOnly }
        if debug != nil {
            // Tag the icon so a debug build is never mistaken for the real one.
            let title = NSMutableAttributedString(attributedString: button.attributedTitle)
            title.append(NSAttributedString(
                string: " DBG",
                attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: NSColor.systemOrange]
            ))
            button.attributedTitle = title
            button.imagePosition = .imageLeading
            button.toolTip = "[debug] " + (button.toolTip ?? "")
        }
        button.setAccessibilityLabel(button.toolTip)
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Snapshot before markSeen so the menu still highlights what was new.
        session.snapshotFailures = model.unseenFailures
        model.markSeen()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover.performClose(nil)
    }
}
