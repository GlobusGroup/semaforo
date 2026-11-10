import AppKit
import Observation
import Sparkle

/// Sparkle, which keeps the shared Semaforo.app up to date from the appcast attached to the latest
/// GitHub release (`SUFeedURL` in Info.plist; published by scripts/release.sh).
///
/// Only release builds carry the feed: build-app.sh strips `SUFeedURL` from local builds, which
/// would otherwise offer to replace themselves with the published app. Without it Sparkle never
/// starts and Settings says updates are off.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Sparkle is running: a release build with a feed, outside debug mode.
    let isActive: Bool
    /// False while a check is already under way.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let reminders = Reminders()
    @ObservationIgnored private let relauncher = Relauncher()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        let hasFeed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.isEmpty == false
        isActive = hasFeed && !DebugController.isEnabled
        controller = SPUStandardUpdaterController(
            startingUpdater: isActive, updaterDelegate: relauncher, userDriverDelegate: reminders
        )
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
    }

    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.checksAutomatically) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Sparkle installs once the app quits, but AppKit turns down a quit ("User cancelled") while a
/// window has a sheet attached. Updates are usually started from the Settings sheet, so close any
/// sheets first, or the installer waits forever for an app that never quits.
private final class Relauncher: NSObject, SPUUpdaterDelegate {
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
        }
    }
}

/// Semaforo is a menu bar app (no Dock icon), so a window Sparkle opens on its daily check would sit
/// behind whatever the user is doing. Opting into gentle reminders tells Sparkle we handle that:
/// we bring the app forward so the "new version available" window is actually seen.
private final class Reminders: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        NSApp.activate()
    }
}
