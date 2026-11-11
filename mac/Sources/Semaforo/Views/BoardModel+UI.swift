import AppKit
import Foundation

/// Sidebar / table filter in the projects window.
enum RunFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case failing = "Failing"

    var id: Self { self }

    func matches(_ repo: RepoSummary) -> Bool {
        switch self {
        case .all: true
        case .running: repo.hasLive
        case .failing: repo.latest?.signal == .failure
        }
    }

    func matches(_ run: WorkflowRun) -> Bool {
        switch self {
        case .all: true
        case .running: run.isLive
        case .failing: run.signal == .failure
        }
    }
}

extension BoardModel {
    /// Repos for the sidebar and the overview, most recently changed first. A live run counts as
    /// a change right now, so repos with runs in progress come first anyway.
    func sidebarRepos(filter: RunFilter, search: String) -> [RepoSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return repos
            .filter { repo in
                filter.matches(repo) && (query.isEmpty
                    || repo.fullName.localizedCaseInsensitiveContains(query)
                    || repo.runs.contains { $0.matches(query) })
            }
            .sorted { a, b in
                if a.hasLive != b.hasLive { return a.hasLive }
                return a.lastChange != b.lastChange ? a.lastChange > b.lastChange : a.fullName < b.fullName
            }
    }

    /// "Recent activity": every run, newest first.
    func activity(filter: RunFilter, search: String) -> [WorkflowRun] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return visibleRuns
            .filter { filter.matches($0) && (query.isEmpty || $0.matches(query)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// The menu's "New failures": what was unseen when it opened plus anything that failed since,
    /// using the freshest copy of each run and dropping ones that are no longer failing (re-run)
    /// or whose repo was switched off while the menu was open.
    func menuFailures(snapshot: [WorkflowRun]) -> [WorkflowRun] {
        let current = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var byID: [Int: WorkflowRun] = [:]
        for run in snapshot { byID[run.id] = current[run.id] ?? run }
        for run in unseenFailures { byID[run.id] = run }
        return byID.values
            .filter { $0.signal == .failure && notifies($0.repoFullName) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// How repos are named on screen. When every repo has the same owner (an org), the owner adds
/// nothing, so only the repo name is shown; with several owners, full "owner/repo" names stay.
struct RepoNaming: Sendable, Equatable {
    var hiddenOwner: String?

    static let full = RepoNaming(hiddenOwner: nil)

    init(hiddenOwner: String?) { self.hiddenOwner = hiddenOwner }

    init(fullNames: some Sequence<String>) {
        let owners = Set(fullNames.compactMap { $0.split(separator: "/", maxSplits: 1).first.map(String.init) })
        hiddenOwner = owners.count == 1 ? owners.first : nil
    }

    /// "org/repo" → "repo" when the owner is hidden, otherwise unchanged.
    func name(_ fullName: String) -> String {
        guard let hiddenOwner, fullName.hasPrefix(hiddenOwner + "/") else { return fullName }
        return String(fullName.dropFirst(hiddenOwner.count + 1))
    }

    /// The owner to show under a repo name, if any.
    func owner(_ fullName: String) -> String? {
        let parts = fullName.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, String(parts[0]) != hiddenOwner else { return nil }
        return String(parts[0])
    }
}

extension BoardModel {
    var repoNaming: RepoNaming { RepoNaming(fullNames: runs.map(\.repoFullName)) }
}

extension RepoSummary {
    /// When this repo last had a run start. Not `updated_at`: GitHub bumps that after a run
    /// finishes (logs, artifacts), which made quiet repos jump to the top.
    var lastChange: Date {
        runs.map(\.startedAt).max() ?? .distantPast
    }
}

extension WorkflowRun {
    func matches(_ query: String) -> Bool {
        [repoFullName, workflowName, displayTitle, headBranch ?? "", actorLogin ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// How long it ran (finished) or has been running so far (live).
    func duration(now: Date) -> TimeInterval {
        max(0, (isLive ? now : updatedAt).timeIntervalSince(startedAt))
    }

    func open() {
        if let url { NSWorkspace.shared.open(url) }
    }
}

enum RunFormat {
    /// GitHub style: "42s", "1m 13s", "1h 2m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func repoActionsURL(_ fullName: String) -> URL? {
        URL(string: "https://github.com/\(fullName)/actions")
    }
}
