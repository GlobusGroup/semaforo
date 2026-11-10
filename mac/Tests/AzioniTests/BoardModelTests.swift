import Foundation
import Testing
@testable import Azioni

// MARK: Fakes

/// Mutable clock shared between the test and the model.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

/// Returns scripted results in order; repeats the last one when exhausted.
actor FakeRunSource: RunSource {
    private var results: [Result<RunsSnapshot, GitHubError>]
    private(set) var calls: [Bool] = []

    private let delay: Duration

    init(_ results: [Result<RunsSnapshot, GitHubError>] = [], delay: Duration = .zero) {
        self.results = results
        self.delay = delay
    }

    func push(_ result: Result<RunsSnapshot, GitHubError>) { results.append(result) }

    func scan(force: Bool) async throws -> RunsSnapshot {
        calls.append(force)
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !results.isEmpty else {
            throw GitHubError(message: "no script", status: 0, kind: .http)
        }
        let next = results.count > 1 ? results.removeFirst() : results[0]
        return try next.get()
    }
}

@MainActor
final class FakeNotifier: Notifying {
    var authorizationRequests = 0
    var batches: [[WorkflowRun]] = []
    func requestAuthorization() { authorizationRequests += 1 }
    func notifyFailures(_ runs: [WorkflowRun]) { batches.append(runs) }
}

// MARK: Helpers

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func makeRun(
    id: Int,
    repo: String = "org/app",
    status: String = "completed",
    conclusion: String? = "success",
    updated: Date = t0,
    started: Date? = nil,
    workflow: String = "CI",
    branch: String? = "main"
) -> WorkflowRun {
    WorkflowRun(
        id: id, name: workflow, displayTitle: "Commit \(id)", status: status,
        conclusion: conclusion, htmlURL: "https://github.com/\(repo)/actions/runs/\(id)",
        runStartedAt: started ?? updated.addingTimeInterval(-60),
        createdAt: (started ?? updated).addingTimeInterval(-60), updatedAt: updated,
        headBranch: branch, event: "push", actorLogin: "dev", repoFullName: repo,
        workflowName: workflow, runNumber: id
    )
}

func snapshot(_ runs: [WorkflowRun], rateLimitedUntil: Date? = nil) -> RunsSnapshot {
    var sync = SyncInfo()
    sync.rateLimitedUntil = rateLimitedUntil
    return RunsSnapshot(fetchedAt: t0, repoCount: 1, runs: runs, sync: sync)
}

func freshDefaults() -> UserDefaults {
    let name = "azioni-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
func makeModel(
    _ source: FakeRunSource,
    clock: TestClock = TestClock(t0),
    defaults: UserDefaults = freshDefaults(),
    notifier: FakeNotifier = FakeNotifier()
) -> BoardModel {
    BoardModel(store: source, notifier: notifier, defaults: defaults, now: { clock.now })
}

// MARK: Seen model

@MainActor
@Suite struct SeenModelTests {
    @Test func firstLaunchSetsLastSeenToLaunchTimeAndPersists() {
        let defaults = freshDefaults()
        let model = makeModel(FakeRunSource(), defaults: defaults)
        #expect(model.lastSeenAt == t0)
        #expect(defaults.object(forKey: BoardModel.lastSeenKey) as? Date == t0)
    }

    @Test func laterLaunchKeepsPersistedLastSeen() {
        let defaults = freshDefaults()
        let earlier = t0.addingTimeInterval(-3600)
        defaults.set(earlier, forKey: BoardModel.lastSeenKey)
        let model = makeModel(FakeRunSource(), defaults: defaults)
        #expect(model.lastSeenAt == earlier)
    }

    @Test func oldFailuresAreNotUnseen() async {
        let old = makeRun(id: 1, conclusion: "failure", updated: t0.addingTimeInterval(-600))
        let model = makeModel(FakeRunSource([.success(snapshot([old]))]))
        await model.refresh()
        #expect(model.runs.count == 1)
        #expect(model.unseenFailures.isEmpty)
        #expect(model.iconState == .idle)
    }

    @Test func failureAfterLastSeenIsUnseen() async {
        let fresh = makeRun(id: 2, conclusion: "timed_out", updated: t0.addingTimeInterval(30))
        let model = makeModel(FakeRunSource([.success(snapshot([fresh]))]))
        await model.refresh()
        #expect(model.unseenFailures.map(\.id) == [2])
        #expect(model.iconState == .failures(unseen: 1, running: 0))
    }

    @Test func markSeenClearsBadgeAndPersists() async {
        let clock = TestClock(t0)
        let defaults = freshDefaults()
        let fresh = makeRun(id: 2, conclusion: "failure", updated: t0.addingTimeInterval(30))
        let model = makeModel(
            FakeRunSource([.success(snapshot([fresh]))]), clock: clock, defaults: defaults
        )
        await model.refresh()
        #expect(model.unseenFailures.count == 1)

        clock.advance(60)
        model.markSeen()
        #expect(model.lastSeenAt == t0.addingTimeInterval(60))
        #expect(model.unseenFailures.isEmpty)
        #expect(model.iconState == .idle)
        #expect(defaults.object(forKey: BoardModel.lastSeenKey) as? Date == t0.addingTimeInterval(60))

        // A relaunch picks up the persisted value.
        let relaunched = makeModel(FakeRunSource(), clock: clock, defaults: defaults)
        #expect(relaunched.lastSeenAt == t0.addingTimeInterval(60))
    }
}

// MARK: Notifications

@MainActor
@Suite struct NewFailureTests {
    @Test func firstScanPostsNothing() async {
        let notifier = FakeNotifier()
        let failed = makeRun(id: 1, conclusion: "failure", updated: t0.addingTimeInterval(5))
        let model = makeModel(FakeRunSource([.success(snapshot([failed]))]), notifier: notifier)
        await model.refresh()
        #expect(notifier.batches.isEmpty)
        // Unchanged on the next scan: still nothing.
        await model.refresh()
        #expect(notifier.batches.isEmpty)
    }

    @Test func runningToFailurePostsOne() async {
        let notifier = FakeNotifier()
        let running = makeRun(id: 7, status: "in_progress", conclusion: nil, updated: t0.addingTimeInterval(5))
        let failed = makeRun(id: 7, conclusion: "failure", updated: t0.addingTimeInterval(90))
        let source = FakeRunSource([.success(snapshot([running])), .success(snapshot([failed]))])
        let model = makeModel(source, notifier: notifier)

        await model.refresh()
        #expect(model.iconState == .running(1))
        await model.refresh()
        #expect(notifier.batches.count == 1)
        #expect(notifier.batches.first?.map(\.id) == [7])
        // Staying failed doesn't re-notify.
        await model.refresh()
        #expect(notifier.batches.count == 1)
    }

    @Test func newRunIdAlreadyFailedPostsButOldOnesDoNot() async {
        let notifier = FakeNotifier()
        let source = FakeRunSource([
            .success(snapshot([])),
            .success(snapshot([
                makeRun(id: 10, conclusion: "failure", updated: t0.addingTimeInterval(20)),
                // Finished before launch (repo checked late): no notification.
                makeRun(id: 11, conclusion: "failure", updated: t0.addingTimeInterval(-20)),
            ])),
        ])
        let model = makeModel(source, notifier: notifier)
        await model.refresh()
        await model.refresh()
        #expect(notifier.batches.map { $0.map(\.id) } == [[10]])
    }

    @Test func fourNewFailuresInOneScanAreOneCall() async {
        let notifier = FakeNotifier()
        let running = (1...4).map {
            makeRun(id: $0, repo: "org/r\($0)", status: "in_progress", conclusion: nil, updated: t0)
        }
        let failed = (1...4).map {
            makeRun(id: $0, repo: "org/r\($0)", conclusion: "failure", updated: t0.addingTimeInterval(60))
        }
        let source = FakeRunSource([.success(snapshot(running)), .success(snapshot(failed))])
        let model = makeModel(source, notifier: notifier)
        await model.refresh()
        await model.refresh()
        #expect(notifier.batches.count == 1)
        #expect(notifier.batches[0].count == 4)
    }

    @Test func failedScanDoesNotResetBaseline() async {
        let notifier = FakeNotifier()
        let running = makeRun(id: 3, status: "in_progress", conclusion: nil, updated: t0)
        let failed = makeRun(id: 3, conclusion: "failure", updated: t0.addingTimeInterval(60))
        let source = FakeRunSource([
            .success(snapshot([running])),
            .failure(GitHubError(message: "x", status: 0, kind: .offline)),
            .success(snapshot([failed])),
        ])
        let model = makeModel(source, notifier: notifier)
        await model.refresh()
        await model.refresh()
        await model.refresh()
        #expect(notifier.batches.map { $0.map(\.id) } == [[3]])
    }
}

// MARK: Notifier plan

@Suite struct NotifierPlanTests {
    @Test func upToThreeAreIndividual() {
        let runs = (1...3).map { makeRun(id: $0, conclusion: "failure", branch: "feat/\($0)") }
        let plan = Notifier.plan(for: runs)
        #expect(plan.count == 3)
        #expect(plan[0].title == "org/app · CI failed on feat/1")
        #expect(plan[0].body == "Commit 1")
        #expect(plan[0].url == "https://github.com/org/app/actions/runs/1")
    }

    @Test func moreThanThreeBecomeOneSummary() {
        let runs = (1...4).map { makeRun(id: $0, repo: "org/r\($0)", conclusion: "failure") }
        let plan = Notifier.plan(for: runs)
        #expect(plan.count == 1)
        #expect(plan[0].title == "4 workflows failed")
        #expect(plan[0].url == runs[0].htmlURL)
    }

    @Test func emptyPlansNothing() {
        #expect(Notifier.plan(for: []).isEmpty)
    }

    @Test func noBranchOmitsOn() {
        let run = makeRun(id: 1, conclusion: "failure", branch: nil)
        #expect(Notifier.title(for: run) == "org/app · CI failed")
    }
}

// MARK: Problems, priority, grouping

@MainActor
@Suite struct BoardStateTests {
    @Test func thrownScanSetsProblemAndKeepsRuns() async {
        let ok = makeRun(id: 1)
        let source = FakeRunSource([
            .success(snapshot([ok])),
            .failure(GitHubError(message: "nope", status: 0, kind: .noToken)),
        ])
        let model = makeModel(source)
        await model.refresh()
        #expect(model.problem == nil)
        await model.refresh()
        #expect(model.runs.map(\.id) == [1])
        #expect(model.problem?.contains("gh auth login") == true)
        #expect(model.iconState == .problem)
    }

    @Test func errorMessages() {
        #expect(BoardModel.describe(GitHubError(message: "x", status: 0, kind: .offline)) == "Offline")
        #expect(BoardModel.describe(GitHubError(message: "Boom 500", status: 500, kind: .http)) == "Boom 500")
        let until = t0.addingTimeInterval(600)
        let limited = BoardModel.describe(
            GitHubError(message: "x", status: 403, kind: .rateLimited(until: until)), now: t0
        )
        #expect(limited == "Rate limited until \(BoardModel.clockTime(until))")
    }

    @Test func rateLimitedSnapshotSetsProblem() async {
        let until = t0.addingTimeInterval(300)
        let model = makeModel(FakeRunSource([.success(snapshot([makeRun(id: 1)], rateLimitedUntil: until))]))
        await model.refresh()
        #expect(model.problem == "GitHub rate limit reached; resets at \(BoardModel.clockTime(until))")
        #expect(model.iconState == .problem)
    }

    @Test func checkOnlyForRecentSuccess() async {
        let passedRecently = makeRun(id: 1, updated: t0.addingTimeInterval(-3600))
        let passedLongAgo = makeRun(id: 2, updated: t0.addingTimeInterval(-2 * 86_400))
        let seenFailureAfter = makeRun(id: 3, conclusion: "failure", updated: t0.addingTimeInterval(-1800))
        let cancelledAfter = makeRun(id: 4, conclusion: "cancelled", updated: t0.addingTimeInterval(-60))
        let model = makeModel(FakeRunSource([
            .success(snapshot([passedRecently])),
            .success(snapshot([passedLongAgo])),
            .success(snapshot([passedRecently, seenFailureAfter])),
            .success(snapshot([passedRecently, cancelledAfter])),
            .success(snapshot([])),
        ]))
        await model.refresh()
        #expect(model.iconState == .passed)
        await model.refresh()
        #expect(model.iconState == .idle)   // too old
        await model.refresh()
        #expect(model.iconState == .idle)   // newest finished run failed (already seen)
        await model.refresh()
        #expect(model.iconState == .idle)   // newest finished run was cancelled
        await model.refresh()
        #expect(model.iconState == .idle)   // no runs
    }

    @Test func iconPriority() async {
        let live = makeRun(id: 1, status: "queued", conclusion: nil, updated: t0.addingTimeInterval(10))
        let unseen = makeRun(id: 2, conclusion: "failure", updated: t0.addingTimeInterval(10))
        let error = GitHubError(message: "x", status: 0, kind: .offline)
        let source = FakeRunSource([
            .success(snapshot([live, unseen])),
            .failure(error),                    // keeps runs: still failures first
            .success(snapshot([live])),
            .failure(error),                    // live beats problem
            .success(snapshot([])),
            .failure(error),                    // only the problem
            .success(snapshot([])),
        ])
        let model = makeModel(source)

        await model.refresh()
        #expect(model.iconState == .failures(unseen: 1, running: 1))
        await model.refresh()
        #expect(model.iconState == .failures(unseen: 1, running: 1))
        await model.refresh()
        #expect(model.iconState == .running(1))
        await model.refresh()
        #expect(model.iconState == .running(1))
        await model.refresh()
        #expect(model.iconState == .idle)
        await model.refresh()
        #expect(model.iconState == .problem)
        await model.refresh()
        #expect(model.iconState == .idle)
    }

    @Test func refreshForcesAndDerivedLists() async {
        let runs = (1...10).map { i in
            makeRun(
                id: i, repo: i % 2 == 0 ? "org/even" : "org/odd",
                status: i == 1 ? "in_progress" : "completed",
                conclusion: i == 1 ? nil : "success",
                updated: t0.addingTimeInterval(Double(-i * 60))
            )
        }
        let source = FakeRunSource([.success(snapshot(runs))])
        let model = makeModel(source)
        await model.refresh()
        #expect(await source.calls == [true])
        #expect(model.recentRuns.map(\.id) == Array(1...8))
        #expect(model.liveRuns.map(\.id) == [1])
        #expect(model.repos.map(\.fullName) == ["org/odd", "org/even"])
        #expect(model.repos[0].latest?.id == 1)
        #expect(model.repos[1].runs.map(\.id) == [2, 4, 6, 8, 10])
        #expect(model.isRefreshing == false)
        #expect(model.fetchedAt == t0)
    }

    @Test func startScansImmediatelyAndIsIdempotent() async throws {
        let source = FakeRunSource([.success(snapshot([makeRun(id: 1)]))])
        let model = BoardModel(
            store: source, notifier: FakeNotifier(), defaults: freshDefaults(),
            now: { t0 }, pollInterval: .seconds(3600)
        )
        model.start()
        model.start()
        for _ in 0..<200 where model.runs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.stop()
        #expect(model.runs.map(\.id) == [1])
        #expect(await source.calls == [false])
    }

    @Test func concurrentScansDoNotOverlap() async {
        let source = FakeRunSource([.success(snapshot([makeRun(id: 1)]))], delay: .milliseconds(100))
        let model = makeModel(source)
        async let a: Void = model.refresh()
        async let b: Void = model.refresh()
        _ = await (a, b)
        #expect(await source.calls.count == 1)
    }
}

@Test func repoNamingHidesSharedOwner() {
    let shared = RepoNaming(fullNames: ["GlobusGroup/craft", "GlobusGroup/astro"])
    #expect(shared.hiddenOwner == "GlobusGroup")
    #expect(shared.name("GlobusGroup/craft") == "craft")
    #expect(shared.owner("GlobusGroup/craft") == nil)

    let mixed = RepoNaming(fullNames: ["GlobusGroup/craft", "you/dotfiles"])
    #expect(mixed.hiddenOwner == nil)
    #expect(mixed.name("you/dotfiles") == "you/dotfiles")
    #expect(mixed.owner("you/dotfiles") == "you")

    let run = makeRun(id: 1, repo: "GlobusGroup/craft", conclusion: "failure")
    #expect(Notifier.title(for: run, naming: shared) == "craft · CI failed on main")
}
