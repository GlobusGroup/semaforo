import Foundation
import Observation

/// What the menu bar icon shows. Priority: failures > running > problem > ok.
enum IconState: Equatable, Sendable {
    /// Red exclamationmark.triangle.fill with unseen count; running count beside it if > 0.
    case failures(unseen: Int, running: Int)
    /// arrow.triangle.2.circlepath with live run count.
    case running(Int)
    /// checkmark.circle, monochrome.
    case ok
    /// exclamationmark.icloud, dimmed.
    case problem
}

struct RepoSummary: Identifiable, Hashable, Sendable {
    var id: String { fullName }
    var fullName: String
    /// Newest first.
    var runs: [WorkflowRun]
    var latest: WorkflowRun? { runs.first }
    var hasLive: Bool { runs.contains(where: \.isLive) }
    var latestActivity: Date { runs.map(\.updatedAt).max() ?? .distantPast }
}

/// Where BoardModel gets its snapshots from; `RunStore` in the app, a fake in tests.
protocol RunSource: Sendable {
    func scan(force: Bool) async throws -> RunsSnapshot
}

extension RunStore: RunSource {}

@MainActor
@Observable
final class BoardModel {
    static let pollInterval: Duration = .seconds(20)
    static let lastSeenKey = "lastSeenAt"
    static let recentLimit = 8

    private(set) var runs: [WorkflowRun] = []
    private(set) var sync: SyncInfo?
    private(set) var fetchedAt: Date?
    /// Human-readable reason when the last scan failed or GitHub is refusing requests.
    private(set) var problem: String?
    private(set) var lastSeenAt: Date
    private(set) var isRefreshing = false

    /// When this model was created; failures older than this never notify.
    let launchedAt: Date

    @ObservationIgnored private let store: any RunSource
    @ObservationIgnored private let notifier: any Notifying
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Signal per run id from the previous successful snapshot; nil until the first one.
    @ObservationIgnored private var previousSignals: [Int: Signal]?

    init(
        store: any RunSource = RunStore(),
        notifier: any Notifying = Notifier(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        pollInterval: Duration = BoardModel.pollInterval
    ) {
        self.store = store
        self.notifier = notifier
        self.defaults = defaults
        self.now = now
        self.interval = pollInterval
        let launch = now()
        launchedAt = launch
        if let saved = defaults.object(forKey: Self.lastSeenKey) as? Date {
            lastSeenAt = saved
        } else {
            lastSeenAt = launch
            defaults.set(launch, forKey: Self.lastSeenKey)
        }
    }

    // MARK: Derived state

    /// Failed runs whose updatedAt > lastSeenAt.
    var unseenFailures: [WorkflowRun] {
        runs.filter { $0.signal == .failure && $0.updatedAt > lastSeenAt }
    }

    /// Running or queued runs.
    var liveRuns: [WorkflowRun] { runs.filter(\.isLive) }

    /// Latest ~8 runs.
    var recentRuns: [WorkflowRun] { Array(runs.prefix(Self.recentLimit)) }

    /// Every repo with runs, sorted by latest activity.
    var repos: [RepoSummary] {
        var order: [String] = []
        var grouped: [String: [WorkflowRun]] = [:]
        for run in runs {
            if grouped[run.repoFullName] == nil { order.append(run.repoFullName) }
            grouped[run.repoFullName, default: []].append(run)
        }
        return order
            .map { name in
                RepoSummary(
                    fullName: name,
                    runs: grouped[name]!.sorted { $0.startedAt > $1.startedAt }
                )
            }
            .sorted {
                $0.latestActivity != $1.latestActivity
                    ? $0.latestActivity > $1.latestActivity
                    : $0.fullName < $1.fullName
            }
    }

    var iconState: IconState {
        let unseen = unseenFailures.count
        let live = liveRuns.count
        if unseen > 0 { return .failures(unseen: unseen, running: live) }
        if live > 0 { return .running(live) }
        if problem != nil { return .problem }
        return .ok
    }

    // MARK: Actions

    /// Starts the 20s polling loop (idempotent).
    func start() {
        guard pollTask == nil else { return }
        let interval = self.interval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scan(force: false)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stops the polling loop.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Forces a scan now.
    func refresh() async {
        await scan(force: true)
    }

    /// Opening the menu: lastSeenAt = now, persisted; clears the badge.
    func markSeen() {
        let date = now()
        lastSeenAt = date
        defaults.set(date, forKey: Self.lastSeenKey)
    }

    // MARK: Debug hooks

    /// Debug mode: move the seen marker (persisted, like markSeen).
    func setLastSeen(_ date: Date) {
        lastSeenAt = date
        defaults.set(date, forKey: Self.lastSeenKey)
    }

    /// Debug mode: forget everything, as if just launched. The next scan is a baseline again,
    /// so switching scenarios doesn't fire notifications for the fixtures.
    func resetForDebug() {
        runs = []
        sync = nil
        fetchedAt = nil
        problem = nil
        previousSignals = nil
    }

    // MARK: Scanning

    /// Runs one scan, or joins the one already in flight (scans never overlap).
    func scan(force: Bool) async {
        if let inFlight {
            await inFlight.value
            return
        }
        isRefreshing = true
        let task = Task { [weak self] () -> Void in
            await self?.performScan(force: force)
        }
        inFlight = task
        await task.value
        inFlight = nil
        isRefreshing = false
    }

    private func performScan(force: Bool) async {
        do {
            let snapshot = try await store.scan(force: force)
            apply(snapshot)
        } catch {
            problem = Self.describe(error, now: now())
        }
    }

    private func apply(_ snapshot: RunsSnapshot) {
        let fresh = Self.newFailures(
            in: snapshot.runs, previous: previousSignals, launchedAt: launchedAt
        )
        previousSignals = Dictionary(
            snapshot.runs.map { ($0.id, $0.signal) }, uniquingKeysWith: { first, _ in first }
        )
        runs = snapshot.runs
        sync = snapshot.sync
        fetchedAt = snapshot.fetchedAt
        if let until = snapshot.sync.rateLimitedUntil {
            problem = "GitHub rate limit reached; resets at \(Self.clockTime(until))"
        } else {
            problem = nil
        }
        if !fresh.isEmpty { notifier.notifyFailures(fresh) }
    }

    /// Runs that turned into failures since the previous successful snapshot.
    /// `previous == nil` (first successful scan) only records the starting state.
    nonisolated static func newFailures(
        in runs: [WorkflowRun], previous: [Int: Signal]?, launchedAt: Date
    ) -> [WorkflowRun] {
        guard let previous else { return [] }
        return runs.filter { run in
            run.signal == .failure
                && previous[run.id] != .failure
                && run.updatedAt >= launchedAt
        }
    }

    /// Message shown in the menu for a failed scan.
    nonisolated static func describe(_ error: any Error, now: Date = Date()) -> String {
        guard let gh = error as? GitHubError else { return error.localizedDescription }
        switch gh.kind {
        case .noToken:
            return "GitHub CLI not signed in — run gh auth login"
        case .offline:
            return "Offline"
        case .rateLimited(let until):
            if let until, until > now { return "Rate limited until \(clockTime(until))" }
            return "GitHub rate limit reached"
        case .http:
            return gh.message
        }
    }

    /// "09:39" in the local time zone.
    nonisolated static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
