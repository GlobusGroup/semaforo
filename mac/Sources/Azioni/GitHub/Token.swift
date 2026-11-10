import Foundation

/// Supplies a GitHub token. `force` re-reads it (after a 401).
protocol TokenProvider: Sendable {
    func token(force: Bool) async throws -> String
}

/// Reads `gh auth token`. Looks in /opt/homebrew/bin, /usr/local/bin,
/// then falls back to `/bin/zsh -lc 'gh auth token'`. Throws GitHubError(kind: .noToken).
struct GhCLIToken: TokenProvider {
    func token(force: Bool) async throws -> String {
        // TODO(agent: github)
        throw GitHubError(message: "not implemented", status: 401, kind: .noToken)
    }
}
