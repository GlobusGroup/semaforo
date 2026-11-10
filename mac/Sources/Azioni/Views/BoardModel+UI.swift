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
        return runs
            .filter { filter.matches($0) && (query.isEmpty || $0.matches(query)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// The menu's "New failures": what was unseen when it opened plus anything that failed since,
    /// using the freshest copy of each run and dropping ones that are no longer failing (re-run).
    func menuFailures(snapshot: [WorkflowRun]) -> [WorkflowRun] {
        let current = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var byID: [Int: WorkflowRun] = [:]
        for run in snapshot { byID[run.id] = current[run.id] ?? run }
        for run in unseenFailures { byID[run.id] = run }
        return byID.values
            .filter { $0.signal == .failure }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

extension RepoSummary {
    /// When anything last happened in this repo: the latest run start or finish.
    var lastChange: Date {
        runs.map { max($0.updatedAt, $0.startedAt) }.max() ?? .distantPast
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
    /// "42s", "3m 05s", "1h 02m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    static func repoActionsURL(_ fullName: String) -> URL? {
        URL(string: "https://github.com/\(fullName)/actions")
    }
}
