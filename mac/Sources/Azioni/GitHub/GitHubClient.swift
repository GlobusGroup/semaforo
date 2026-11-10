import Foundation

struct GetResult<T: Sendable>: Sendable {
    var data: T
    /// true when GitHub answered 304 (free).
    var notModified: Bool
    var next: URL?
}

/// Port of `server/github.ts`.
actor GitHubClient {
    static let defaultBaseURL = URL(string: "https://api.github.com")!

    private(set) var rateLimit: RateLimitInfo?
    /// Requests are refused locally until then.
    private(set) var rateLimitedUntil: Date?

    init(
        session: URLSession = .shared,
        tokenProvider: any TokenProvider = GhCLIToken(),
        baseURL: URL = GitHubClient.defaultBaseURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        // TODO(agent: github)
    }

    /// `path` is either "/repos/..." (relative to baseURL) or an absolute URL string.
    func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> GetResult<T> {
        // TODO(agent: github)
        throw GitHubError(message: "not implemented", status: 0, kind: .http)
    }

    /// Follows `Link: rel="next"` and concatenates array pages.
    func getAll<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> (data: [T], requests: Int, notModified: Int) {
        // TODO(agent: github)
        throw GitHubError(message: "not implemented", status: 0, kind: .http)
    }
}
