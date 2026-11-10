import Foundation

/// Mirrors `shared/types.ts` `WorkflowRun` (snake_case on the wire).
struct WorkflowRun: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var displayTitle: String
    var status: String
    var conclusion: String?
    var htmlURL: String
    var runStartedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var headBranch: String?
    var event: String
    var actorLogin: String?
    var repoFullName: String
    var workflowName: String
    var runNumber: Int

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, event
        case displayTitle = "display_title"
        case htmlURL = "html_url"
        case runStartedAt = "run_started_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case headBranch = "head_branch"
        case actorLogin = "actor_login"
        case repoFullName = "repo_full_name"
        case workflowName = "workflow_name"
        case runNumber = "run_number"
    }

    /// `run_started_at || created_at`, as in the server's `startedAt`.
    var startedAt: Date { runStartedAt ?? createdAt }
    var signal: Signal { Signal.of(self) }
    var url: URL? { URL(string: htmlURL) }
    var isLive: Bool { signal == .running || signal == .queued }
}

/// Port of `src/lib/status.ts` `signalOf` / `signalLabel`.
enum Signal: String, Sendable, CaseIterable {
    case running, queued, success, failure, cancelled, neutral

    static func of(_ run: WorkflowRun) -> Signal {
        switch run.status {
        case "in_progress", "waiting", "requested": return .running
        case "queued", "pending": return .queued
        default: break
        }
        switch run.conclusion {
        case "success": return .success
        case "failure", "timed_out", "action_required": return .failure
        case "cancelled", "skipped", "stale": return .cancelled
        default: return .neutral
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .queued: "Queued"
        case .success: "Passed"
        case .failure: "Failed"
        case .cancelled: "Stopped"
        case .neutral: "Idle"
        }
    }
}
