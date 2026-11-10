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

        switch state {
        case let .failures(unseen, running):
            button.image = Self.symbol("exclamationmark.triangle.fill", color: .systemRed)
            let title = NSMutableAttributedString(
                string: " \(unseen)",
                attributes: [.font: font, .foregroundColor: NSColor.systemRed]
            )
            if running > 0 {
                title.append(NSAttributedString(
                    string: "  ⟳ \(running)",
                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]
                ))
            }
            button.attributedTitle = title
            button.toolTip = "\(unseen) new failure\(unseen == 1 ? "" : "s")"
                + (running > 0 ? ", \(running) running" : "")
        case let .running(count):
            button.image = Self.symbol("arrow.triangle.2.circlepath", color: .systemBlue)
            button.attributedTitle = NSAttributedString(
                string: " \(count)",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
            button.toolTip = "\(count) running"
        case .ok:
            button.image = Self.symbol("checkmark.circle.fill", color: nil)
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            button.toolTip = "Azioni: all good"
        case .problem:
            // Orange rather than greyed out: a disabled-looking icon is easy to miss entirely.
            button.image = Self.symbol("exclamationmark.icloud.fill", color: .systemOrange)
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            button.toolTip = model.problem ?? "Azioni can't reach GitHub"
        }
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

    /// Coloured (non-template) when `color` is given, otherwise a template image that follows the menu bar.
    private static func symbol(_ name: String, color: NSColor?) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        // 16pt semibold reads like the system's own menu extras; 14pt regular was too faint.
        var config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        if let color {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = color == nil
        return image
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
