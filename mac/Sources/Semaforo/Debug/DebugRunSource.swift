import Foundation

/// What the debug source feeds BoardModel instead of (or on top of) GitHub.
enum DebugScenario: String, CaseIterable, Identifiable, Sendable {
    case live, idle, allGood, running, failures, busy, noToken, rateLimited, offline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .live: "Live GitHub"
        case .idle: "Idle (nothing in 24 h)"
        case .allGood: "All good (passed recently)"
        case .running: "3 running"
        case .failures: "2 new failures + 1 running"
        case .busy: "Busy board (8 repos)"
        case .noToken: "Problem: gh not signed in"
        case .rateLimited: "Problem: rate limited"
        case .offline: "Problem: offline"
        }
    }
}

/// Sits between BoardModel and RunStore. In `.live` it passes GitHub through; otherwise it serves
/// fixtures. Runs injected by the debug menu are layered on top in every scenario, so notifications
/// and the badge go through the real BoardModel code paths.
actor DebugRunSource: RunSource {
    private let live: RunStore
    private var scenario: DebugScenario = .live
    private var fixtures: [WorkflowRun] = []
    private var injected: [WorkflowRun] = []
    private var nextID = 9_000_000_000

    init(live: RunStore, scenario: DebugScenario = .live, now: Date = Date()) {
        self.live = live
        self.scenario = scenario
        fixtures = DebugFixtures.runs(for: scenario, now: now)
    }

    func select(_ scenario: DebugScenario, now: Date) {
        self.scenario = scenario
        fixtures = DebugFixtures.runs(for: scenario, now: now)
        injected = []
    }

    /// Adds a run in progress (shows as running).
    func startRun(now: Date) {
        injected.insert(makeRun(status: "in_progress", conclusion: nil, now: now), at: 0)
    }

    /// Completes every injected live run with `conclusion` ("success" / "failure").
    func finishRuns(conclusion: String, now: Date) -> Int {
        var finished = 0
        for i in injected.indices where injected[i].isLive {
            injected[i].status = "completed"
            injected[i].conclusion = conclusion
            injected[i].updatedAt = now
            finished += 1
        }
        return finished
    }

    /// Adds `count` runs that just failed.
    func addFailures(_ count: Int, now: Date) {
        for _ in 0..<count {
            injected.insert(makeRun(status: "completed", conclusion: "failure", now: now), at: 0)
        }
    }

    func clearInjected() {
        injected = []
    }

    func scan(force: Bool) async throws -> RunsSnapshot {
        let now = Date()
        switch scenario {
        case .live:
            var snapshot = try await live.scan(force: force)
            snapshot.runs = Self.sorted(injected + snapshot.runs)
            return snapshot
        case .noToken:
            throw GitHubError(
                message: "Could not get a token from the GitHub CLI. Run `gh auth login`.",
                status: 401, kind: .noToken)
        case .rateLimited:
            let until = now.addingTimeInterval(14 * 60)
            throw GitHubError(
                message: "GitHub API rate limit reached.", status: 403, kind: .rateLimited(until: until))
        case .offline:
            throw GitHubError(message: "The Internet connection appears to be offline.", status: 0, kind: .offline)
        case .idle, .allGood, .running, .failures, .busy:
            let runs = Self.sorted(injected + fixtures)
            return RunsSnapshot(
                fetchedAt: now,
                repoCount: Set(runs.map(\.repoFullName)).count,
                runs: runs,
                sync: SyncInfo(rateLimit: RateLimitInfo(limit: 5000, remaining: 4210, resetAt: now.addingTimeInterval(40 * 60)))
            )
        }
    }

    private func makeRun(status: String, conclusion: String?, now: Date) -> WorkflowRun {
        nextID += 1
        let n = nextID - 9_000_000_000
        let repo = DebugFixtures.repos[n % DebugFixtures.repos.count]
        return DebugFixtures.run(
            id: nextID, repo: repo, workflow: "Debug CI", title: "Debug run #\(n)", branch: "debug/\(n)",
            status: status, conclusion: conclusion, started: now, updated: now)
    }

    private static func sorted(_ runs: [WorkflowRun]) -> [WorkflowRun] {
        runs.sorted { $0.startedAt > $1.startedAt }
    }
}

enum DebugFixtures {
    static let repos = ["acme/web", "acme/api", "acme/mobile", "acme/infra", "acme/docs", "acme/design-system", "you/dotfiles", "you/blog"]

    static func run(
        id: Int, repo: String, workflow: String, title: String, branch: String,
        status: String, conclusion: String?, started: Date, updated: Date, event: String = "push"
    ) -> WorkflowRun {
        WorkflowRun(
            id: id, name: workflow, displayTitle: title, status: status, conclusion: conclusion,
            htmlURL: "https://github.com/\(repo)/actions", runStartedAt: started, createdAt: started,
            updatedAt: updated, headBranch: branch, event: event, actorLogin: "octocat",
            repoFullName: repo, workflowName: workflow, runNumber: id % 1000)
    }

    /// Fixture runs. Failures are stamped `now` so they count as unseen even though you pick the
    /// scenario from the menu (opening the menu marks everything before that moment as seen).
    static func runs(for scenario: DebugScenario, now: Date) -> [WorkflowRun] {
        var id = 8_000_000_000
        func make(_ repo: String, _ workflow: String, _ title: String, _ branch: String,
                  _ status: String, _ conclusion: String?, minutesAgo: Double, took: Double = 3) -> WorkflowRun {
            id += 1
            let started = now.addingTimeInterval(-minutesAgo * 60)
            let updated = conclusion == nil ? now : started.addingTimeInterval(took * 60)
            return run(id: id, repo: repo, workflow: workflow, title: title, branch: branch,
                       status: status, conclusion: conclusion, started: started, updated: updated)
        }
        let passed = [
            make("acme/web", "CI", "Tidy header spacing", "main", "completed", "success", minutesAgo: 25),
            make("acme/api", "CI", "Bump dependencies", "main", "completed", "success", minutesAgo: 70),
            make("acme/docs", "Deploy", "Publish docs", "main", "completed", "success", minutesAgo: 180),
            make("you/dotfiles", "Lint", "zsh: faster prompt", "main", "completed", "success", minutesAgo: 600),
        ]
        switch scenario {
        case .live, .noToken, .rateLimited, .offline:
            return []
        case .idle:
            return [
                make("acme/web", "CI", "Tidy header spacing", "main", "completed", "success", minutesAgo: 60 * 30),
                make("acme/api", "CI", "Try a new cache key", "main", "completed", "cancelled", minutesAgo: 60 * 50),
                make("you/dotfiles", "Lint", "zsh: faster prompt", "main", "completed", "success", minutesAgo: 60 * 72),
            ]
        case .allGood:
            return passed
        case .running:
            return [
                make("acme/web", "CI", "Add search page", "feature/search", "in_progress", nil, minutesAgo: 2),
                make("acme/api", "Deploy", "Release 2.4.0", "main", "in_progress", nil, minutesAgo: 6),
                make("acme/mobile", "Build", "Fix login crash", "fix/login", "queued", nil, minutesAgo: 0.5),
            ] + passed
        case .failures:
            var failed = [
                make("acme/api", "CI", "Migrate to Postgres 17", "db/pg17", "completed", "failure", minutesAgo: 4),
                make("acme/infra", "Terraform plan", "Rotate certificates", "main", "completed", "timed_out", minutesAgo: 12),
            ]
            for i in failed.indices { failed[i].updatedAt = now }
            return failed + [
                make("acme/web", "CI", "Add search page", "feature/search", "in_progress", nil, minutesAgo: 2),
            ] + passed
        case .busy:
            var runs: [WorkflowRun] = []
            let outcomes: [(String, String?)] = [
                ("in_progress", nil), ("completed", "success"), ("completed", "failure"),
                ("completed", "success"), ("queued", nil), ("completed", "cancelled"),
            ]
            for (r, repo) in repos.enumerated() {
                for k in 0..<5 {
                    let (status, conclusion) = outcomes[(r + k) % outcomes.count]
                    // Only the newest run per repo may be live.
                    let live = conclusion == nil && k == 0
                    runs.append(make(
                        repo, ["CI", "Deploy", "Lint"][k % 3], "Change \(r * 5 + k)", k == 0 ? "main" : "feature/\(k)",
                        live ? status : "completed", live ? nil : (conclusion ?? "success"),
                        minutesAgo: Double(r * 40 + k * 90 + 1)))
                }
            }
            return runs
        }
    }
}
