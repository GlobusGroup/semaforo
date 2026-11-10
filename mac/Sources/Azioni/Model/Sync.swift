import Foundation

/// Mirrors `shared/types.ts` RateLimitInfo / SyncInfo / RunsResponse.
struct RateLimitInfo: Sendable, Equatable {
    var limit: Int
    var remaining: Int
    var resetAt: Date
}

struct Tiers: Sendable, Equatable {
    var active = 0
    var recent = 0
    var quiet = 0
}

struct ScanStats: Sendable, Equatable {
    var reposChecked = 0
    var requests = 0
    var notModified = 0
}

struct SyncInfo: Sendable, Equatable {
    var rateLimit: RateLimitInfo?
    /// Set while GitHub is refusing requests; cached runs are still served.
    var rateLimitedUntil: Date?
    var reposFailed = 0
    /// Repos not checked yet (first load still filling in).
    var reposPending = 0
    var tiers = Tiers()
    var lastScan = ScanStats()
    var warning: String?
}

struct RunsSnapshot: Sendable, Equatable {
    var fetchedAt: Date
    var repoCount: Int
    /// All runs, newest first by `startedAt`.
    var runs: [WorkflowRun]
    var sync: SyncInfo
}

/// Port of the server's `GitHubError`.
struct GitHubError: Error, LocalizedError, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// `gh` missing or not signed in, or a 401 that survived a token re-read.
        case noToken
        /// 403/429 with the budget exhausted, or refused locally until the reset.
        case rateLimited(until: Date?)
        /// Transport failure: offline, DNS, timeout.
        case offline
        /// Any other HTTP status.
        case http
    }

    var message: String
    var status: Int
    var kind: Kind

    var rateLimited: Bool { if case .rateLimited = kind { true } else { false } }
    var errorDescription: String? { message }
}
