import Foundation
import Testing
@testable import Azioni

@MainActor
private final class RecordingNotifier: Notifying {
    var posted: [[WorkflowRun]] = []
    func requestAuthorization() {}
    func notifyFailures(_ runs: [WorkflowRun]) { posted.append(runs) }
}

@MainActor
struct DebugModeTests {
    private func makeModel() async -> (BoardModel, DebugRunSource, RecordingNotifier) {
        let defaults = UserDefaults(suiteName: "debug-tests-\(UUID().uuidString)")!
        let source = DebugRunSource(live: RunStore())
        let notifier = RecordingNotifier()
        // Launched a minute ago, so runs stamped "now" are after launch and after lastSeenAt.
        let launch = Date().addingTimeInterval(-60)
        let model = BoardModel(store: source, notifier: notifier, defaults: defaults, now: { launch }, defaultNotifyScope: .all)
        return (model, source, notifier)
    }

    @Test func scenariosDriveTheIcon() async {
        let (model, source, _) = await makeModel()

        await source.select(.idle, now: Date())
        await model.scan(force: false)
        #expect(model.iconState == .idle)

        await source.select(.allGood, now: Date())
        await model.scan(force: false)
        #expect(model.iconState == .passed)

        await source.select(.running, now: Date())
        await model.scan(force: false)
        #expect(model.iconState == .running(3))

        await source.select(.failures, now: Date())
        await model.scan(force: false)
        #expect(model.iconState == .failures(unseen: 2, running: 1))

        model.resetForDebug()
        await source.select(.noToken, now: Date())
        await model.scan(force: false)
        #expect(model.iconState == .problem)
        #expect(model.problem?.contains("gh auth login") == true)
    }

    @Test func injectedRunsGoThroughNotifications() async {
        let (model, source, notifier) = await makeModel()
        await source.select(.allGood, now: Date())
        await model.scan(force: false) // baseline
        #expect(notifier.posted.isEmpty)

        await source.startRun(now: Date())
        await model.scan(force: false)
        #expect(model.iconState == .running(1))

        let finished = await source.finishRuns(conclusion: "failure", now: Date())
        #expect(finished == 1)
        await model.scan(force: false)
        #expect(notifier.posted.map(\.count) == [1])
        #expect(model.iconState == .failures(unseen: 1, running: 0))

        await source.addFailures(4, now: Date())
        await model.scan(force: false)
        #expect(notifier.posted.map(\.count) == [1, 4])
        #expect(Notifier.plan(for: notifier.posted[1]).count == 1) // one summary
    }
}
