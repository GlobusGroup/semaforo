import Foundation
import Observation

/// Debug mode: fake scenarios and injected runs, driven from the menu's Debug section.
///
/// Turn it on with any of:
///   mac/scripts/debug.sh                                  (rebuilds and relaunches in debug mode)
///   open /Applications/Semaforo.app --args -debug YES      (one launch)
///   defaults write com.globusgroup.semaforo debug -bool YES         (every launch; `defaults delete com.globusgroup.semaforo debug` to undo)
///   SEMAFORO_DEBUG=1 swift run Semaforo
@MainActor
@Observable
final class DebugController {
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "debug")
            || ProcessInfo.processInfo.environment["SEMAFORO_DEBUG"] == "1"
    }

    private(set) var scenario: DebugScenario = .live
    /// Last thing a debug action did, shown under the buttons.
    private(set) var status: String?

    @ObservationIgnored let source: DebugRunSource
    @ObservationIgnored private let model: BoardModel
    @ObservationIgnored private let notifier: any Notifying

    /// `-debugScenario <name>` picks the scenario the first scan uses.
    nonisolated static var launchScenario: DebugScenario {
        UserDefaults.standard.string(forKey: "debugScenario").flatMap(DebugScenario.init(rawValue:)) ?? .live
    }

    init(source: DebugRunSource, model: BoardModel, notifier: any Notifying, scenario: DebugScenario = .live) {
        self.scenario = scenario
        self.source = source
        self.model = model
        self.notifier = notifier
    }

    func select(_ scenario: DebugScenario) {
        self.scenario = scenario
        model.resetForDebug()
        perform("Scenario: \(scenario.label)") { source in
            await source.select(scenario, now: Date())
        }
    }

    func startRun() {
        perform("Started a run") { await $0.startRun(now: Date()) }
    }

    func finishRuns(success: Bool) {
        let conclusion = success ? "success" : "failure"
        Task {
            let n = await source.finishRuns(conclusion: conclusion, now: Date())
            await rescan()
            status = n == 0 ? "No debug runs in progress — start one first" : "Finished \(n) run\(n == 1 ? "" : "s"): \(success ? "passed" : "failed")"
        }
    }

    func addFailures(_ count: Int) {
        perform("Added \(count) failure\(count == 1 ? "" : "s") (expect \(count > Notifier.maxIndividual ? "1 summary" : "\(count)") notification\(count == 1 || count > Notifier.maxIndividual ? "" : "s"))") {
            await $0.addFailures(count, now: Date())
        }
    }

    func clearInjected() {
        perform("Cleared debug runs") { await $0.clearInjected() }
    }

    /// Posts a notification directly, bypassing the new-failure detection.
    func testNotification() {
        let now = Date()
        notifier.notifyFailures([DebugFixtures.run(
            id: 9_999_999_999, repo: "acme/web", workflow: "CI", title: "Test notification",
            branch: "main", status: "completed", conclusion: "failure", started: now, updated: now)])
        status = "Posted a test notification"
    }

    /// Moves lastSeenAt back an hour so recent failures count as unseen again.
    func forgetSeen() {
        model.setLastSeen(Date().addingTimeInterval(-3600))
        status = "Seen moved back 1 h — close the menu to see the badge"
    }

    private func perform(_ message: String, _ change: @escaping @Sendable (DebugRunSource) async -> Void) {
        let source = source
        Task {
            await change(source)
            await rescan()
            status = message
        }
    }

    /// A scan that sees the change. `scan` joins one already in flight, which started before the
    /// change, so run another after it. Unforced: live GitHub is only asked about repos already due.
    private func rescan() async {
        if model.isRefreshing { await model.scan(force: false) }
        await model.scan(force: false)
    }
}
