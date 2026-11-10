import Foundation

/// Port of `server/runStore.ts`, same constants and tiering.
actor RunStore {
    init(client: GitHubClient = GitHubClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        // TODO(agent: github)
    }

    /// Runs a scan (only due repos; `force` makes active/recent repos due) and returns the view.
    /// Throws when there is no data at all (first repo list failed, no token).
    func scan(force: Bool = false) async throws -> RunsSnapshot {
        // TODO(agent: github)
        throw GitHubError(message: "not implemented", status: 0, kind: .http)
    }
}
