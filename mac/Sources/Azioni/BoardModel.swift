import Foundation
import Observation

/// What the menu bar icon shows. Priority: failures > running > problem > passed > idle.
enum IconState: Equatable, Sendable {
    /// Red badge with the unseen count; running count beside it if > 0.
    case failures(unseen: Int, running: Int)
    /// Blue badge with the live run count.
    case running(Int)
    /// Can't reach GitHub: dimmed mark, orange badge.
    case problem
    /// Green check: the most recent finished run passed within `BoardModel.recentSuccessWindow`.
    case passed
    /// Plain mark: nothing running, nothing new, no recent success.
    case idle
}

/// Which repos post failure notifications.
enum NotificationScope: String, CaseIterable, Identifiable, Sendable {
    /// Every repo (the original behaviour).
    case all
    /// Only repos in `BoardModel.notifyRepos`.
    case selected
    /// Never.
    case off

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All repositories"
        case .selected: "Selected repositories"
        case .off: "Off"
        }
    }
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
    static let notifyScopeKey = "notifyScope"
    static let notifyReposKey = "notifyRepos"
    static let recentLimit = 8
    /// Runs older than this are hidden from the menu and window (live runs always show).
    static let visibleWindow: TimeInterval = 24 * 60 * 60
    /// How long a passing run keeps the green check on the icon.
    static let recentSuccessWindow: TimeInterval = 24 * 60 * 60

    private(set) var runs: [WorkflowRun] = []
    private(set) var sync: SyncInfo?
    private(set) var fetchedAt: Date?
    /// Human-readable reason when the last scan failed or GitHub is refusing requests.
    private(set) var problem: String?
    private(set) var lastSeenAt: Date
    private(set) var isRefreshing = false
    /// Which repos post notifications; persisted.
    var notifyScope: NotificationScope {
        didSet { defaults.set(notifyScope.rawValue, forKey: Self.notifyScopeKey) }
    }
    /// Full names ("org/repo") that notify when the scope is `.selected`; persisted.
    private(set) var notifyRepos: Set<String>

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
        notifyScope = defaults.string(forKey: Self.notifyScopeKey).flatMap(NotificationScope.init) ?? .all
        notifyRepos = Set(defaults.stringArray(forKey: Self.notifyReposKey) ?? [])
    }

    // MARK: Notification choices

    /// Whether a failure in this repo posts a notification under the current scope.
    func notifies(_ repoFullName: String) -> Bool {
        switch notifyScope {
        case .all: true
        case .selected: notifyRepos.contains(repoFullName)
        case .off: false
        }
    }

    /// Adds or removes a repo from the selected set (used when the scope is `.selected`).
    func setNotifies(_ enabled: Bool, for repoFullName: String) {
        if enabled { notifyRepos.insert(repoFullName) } else { notifyRepos.remove(repoFullName) }
        defaults.set(notifyRepos.sorted(), forKey: Self.notifyReposKey)
    }

    // MARK: Derived state

    /// Failed runs whose updatedAt > lastSeenAt, in repos that notify (Settings › Notifications).
    /// Drives the icon's red count and the menu's "New failures".
    var unseenFailures: [WorkflowRun] {
        runs.filter { $0.signal == .failure && $0.updatedAt > lastSeenAt && notifies($0.repoFullName) }
    }

    /// Running or queued runs.
    var liveRuns: [WorkflowRun] { runs.filter(\.isLive) }

    /// What the menu and window list: runs started in the last 24 hours, plus anything live.
    var visibleRuns: [WorkflowRun] {
        let cutoff = now().addingTimeInterval(-Self.visibleWindow)
        return runs.filter { $0.isLive || $0.startedAt >= cutoff }
    }

    /// Latest ~8 runs.
    var recentRuns: [WorkflowRun] { Array(visibleRuns.prefix(Self.recentLimit)) }

    /// Every repo with a visible run, sorted by latest activity.
    var repos: [RepoSummary] {
        var order: [String] = []
        var grouped: [String: [WorkflowRun]] = [:]
        for run in visibleRuns {
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
        return latestFinishedPassedRecently ? .passed : .idle
    }

    /// The newest completed run (by when it finished) passed, and not too long ago.
    var latestFinishedPassedRecently: Bool {
        guard let latest = runs.filter({ !$0.isLive }).max(by: { $0.updatedAt < $1.updatedAt }) else {
            return false
        }
        return latest.signal == .success
            && now().timeIntervalSince(latest.updatedAt) < Self.recentSuccessWindow
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
        let wanted = fresh.filter { notifies($0.repoFullName) }
        if !wanted.isEmpty {
            (notifier as? Notifier)?.naming = repoNaming
            notifier.notifyFailures(wanted)
        }
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
