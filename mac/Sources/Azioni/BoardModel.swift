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

@MainActor
@Observable
final class BoardModel {
    static let pollInterval: Duration = .seconds(20)
    static let lastSeenKey = "lastSeenAt"

    private(set) var runs: [WorkflowRun] = []
    private(set) var sync: SyncInfo?
    private(set) var fetchedAt: Date?
    /// Human-readable reason when the last scan failed or GitHub is refusing requests.
    private(set) var problem: String?
    private(set) var lastSeenAt: Date
    private(set) var isRefreshing = false

    init(
        store: RunStore = RunStore(),
        notifier: any Notifying = Notifier(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        // TODO(agent: model)
        lastSeenAt = now()
    }

    /// Failed runs whose updatedAt > lastSeenAt.
    var unseenFailures: [WorkflowRun] { [] } // TODO(agent: model)
    /// Running or queued runs.
    var liveRuns: [WorkflowRun] { [] } // TODO(agent: model)
    /// Latest ~8 runs.
    var recentRuns: [WorkflowRun] { [] } // TODO(agent: model)
    /// Every repo with runs, sorted by latest activity.
    var repos: [RepoSummary] { [] } // TODO(agent: model)
    var iconState: IconState { .ok } // TODO(agent: model)

    /// Starts the 20s polling loop (idempotent).
    func start() {} // TODO(agent: model)
    /// Forces a scan now.
    func refresh() async {} // TODO(agent: model)
    /// Opening the menu: lastSeenAt = now, persisted; clears the badge.
    func markSeen() {} // TODO(agent: model)
}
