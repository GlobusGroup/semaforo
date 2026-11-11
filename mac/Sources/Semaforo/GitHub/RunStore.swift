import Foundation

/// Scans repos for workflow runs with tiered polling and ETags; see "How it stays within the rate limit" in the README.
///
/// In-memory view of workflow runs. Concurrent `scan()` calls join one in-flight
/// scan; each scan only asks GitHub about repos whose tier interval has elapsed.
actor RunStore {
    static let concurrency = 8
    static let runsPerRepo = 5
    /// How long the repo list is reused before asking GitHub again.
    static let repoListTTL: TimeInterval = 10 * 60
    /// Repos pushed to (or with a run) within this window poll more often.
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60
    /// Repos pushed to (or with a run started) within this window poll as often as live ones.
    static let hotWindow: TimeInterval = 60 * 60
    /// How often the push probe asks GitHub which repos were pushed to.
    static let probeInterval: TimeInterval = 20
    /// The probe reads one page of the repo list, newest push first.
    static let probePath =
        "/user/repos?per_page=30&affiliation=owner,collaborator,organization_member&sort=pushed"
    /// When the hourly budget drops below this, only repos with live runs are polled.
    static let lowBudget = 500

    enum Tier: Sendable, CaseIterable {
        /// a run is queued or in progress
        case active
        /// pushed or ran in the last hour: a new run is likely
        case hot
        /// pushed or ran recently
        case recent
        /// catches scheduled / manual runs on idle repos
        case quiet

        var interval: TimeInterval {
            switch self {
            case .active: 20
            case .hot: 20
            case .recent: 90
            case .quiet: 15 * 60
            }
        }
    }

    static let activeStatuses: Set<String> = ["queued", "in_progress", "waiting", "requested", "pending"]
    static let repoListPath =
        "/user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=pushed"

    struct RepoState: Sendable {
        var fullName: String
        var pushedAt: Date?
        var runs: [WorkflowRun] = []
        /// nil = never checked
        var checkedAt: Date?
        var error: String?
        /// The push probe saw a new push: check on the next scan whatever the tier says.
        var pushedSinceCheck = false
    }

    private let client: GitHubClient
    private let now: @Sendable () -> Date
    private var repos: [String: RepoState] = [:]
    private var reposFetchedAt: Date?
    private var probedAt: Date?
    private var lastScanAt: Date?
    private var inflight: Task<RunsSnapshot, any Error>?
    private var warning: String?
    private var lastScan = ScanStats()

    init(client: GitHubClient = GitHubClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    /// Runs a scan (only due repos; `force` makes active/recent repos due) and returns the view.
    /// Throws when there is no data at all (first repo list failed, no token).
    func scan(force: Bool = false) async throws -> RunsSnapshot {
        if let inflight { return try await inflight.value }
        let task = Task { try await self.performScan(force: force) }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    // MARK: - Tiering

    private func tier(_ repo: RepoState, at now: Date) -> Tier {
        if repo.runs.contains(where: { Self.activeStatuses.contains($0.status) }) { return .active }
        let latest = [repo.pushedAt, repo.runs.map(\.startedAt).max()].compactMap { $0 }.max()
        if let latest, now.timeIntervalSince(latest) < Self.hotWindow { return .hot }
        if let latest, now.timeIntervalSince(latest) < Self.recentWindow { return .recent }
        return .quiet
    }

    private func isDue(_ repo: RepoState, at now: Date, force: Bool, lowBudget: Bool) -> Bool {
        guard let checkedAt = repo.checkedAt else { return true }
        let tier = tier(repo, at: now)
        if repo.pushedSinceCheck && !lowBudget { return true }
        if lowBudget && tier != .active { return false }
        if force && tier != .quiet { return true }
        return now.timeIntervalSince(checkedAt) >= tier.interval
    }

    // MARK: - Scan

    private enum CheckOutcome: Sendable {
        case runs([WorkflowRun], notModified: Bool)
        case notFound
        case rateLimited
        case failed(String)
    }

    private func performScan(force: Bool) async throws -> RunsSnapshot {
        defer { lastScanAt = now() }
        let started = now()
        warning = nil
        var requests = 0
        var notModified = 0

        if repos.isEmpty || reposFetchedAt.map({ started.timeIntervalSince($0) >= Self.repoListTTL }) ?? true {
            do {
                let res = try await refreshRepos()
                requests += res.requests
                notModified += res.notModified
            } catch {
                if repos.isEmpty { throw error }
                warning = "Repo list refresh failed: \(error.localizedDescription)"
            }
        } else if probedAt.map({ started.timeIntervalSince($0) >= Self.probeInterval }) ?? true {
            // Between full refreshes, one cheap page of the repo list (newest push first) tells us
            // which repos were just pushed to. Unchanged, it's a free 304.
            if let res = try? await probePushes() {
                requests += 1
                if res.notModified { notModified += 1 }
            }
        }

        let lowBudget = (await client.rateLimit?.remaining ?? .max) < Self.lowBudget
        let due = repos.values
            .filter { isDue($0, at: started, force: force, lowBudget: lowBudget) }
            .map(\.fullName)
            .sorted()

        let client = self.client
        await withTaskGroup(of: (String, CheckOutcome).self) { group in
            var pending = due[...]
            func addNext() {
                guard let name = pending.popFirst() else { return }
                group.addTask { (name, await Self.check(name, client: client)) }
            }
            for _ in 0..<Self.concurrency { addNext() }
            while let (name, outcome) = await group.next() {
                addNext()
                switch outcome {
                case .rateLimited:
                    continue // leave checkedAt alone so it is retried once the limit resets
                case let .runs(runs, wasNotModified):
                    requests += 1
                    if wasNotModified { notModified += 1 }
                    repos[name]?.runs = runs
                    repos[name]?.error = nil
                case .notFound:
                    requests += 1
                    repos[name]?.runs = []
                    repos[name]?.error = nil
                case let .failed(message):
                    requests += 1
                    repos[name]?.error = message
                }
                repos[name]?.checkedAt = now()
                repos[name]?.pushedSinceCheck = false
            }
        }

        lastScan = ScanStats(reposChecked: due.count, requests: requests, notModified: notModified)
        lastScanAt = now()
        return await build()
    }

    private static func check(_ fullName: String, client: GitHubClient) async -> CheckOutcome {
        do {
            let res = try await client.get(
                "/repos/\(fullName)/actions/runs?per_page=\(runsPerRepo)", as: GhRunsPage.self)
            let runs = (res.data.workflowRuns ?? []).map { $0.toRun(fullName) }
            return .runs(runs, notModified: res.notModified)
        } catch let error as GitHubError {
            if error.rateLimited { return .rateLimited }
            if error.status == 404 { return .notFound }
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Marks repos whose `pushed_at` moved since we last looked, so this scan checks them.
    private func probePushes() async throws -> (notModified: Bool, pushed: [String]) {
        let res = try await client.get(Self.probePath, as: [GhRepo].self)
        probedAt = now()
        guard !res.notModified else { return (true, []) }
        var pushed: [String] = []
        for repo in res.data where !repo.archived && !repo.disabled {
            if var existing = repos[repo.fullName] {
                if let new = repo.pushedAt, new > (existing.pushedAt ?? .distantPast) {
                    existing.pushedAt = new
                    existing.pushedSinceCheck = true
                    repos[repo.fullName] = existing
                    pushed.append(repo.fullName)
                }
            } else {
                repos[repo.fullName] = RepoState(fullName: repo.fullName, pushedAt: repo.pushedAt)
                pushed.append(repo.fullName)
            }
        }
        return (false, pushed)
    }

    private func refreshRepos() async throws -> (requests: Int, notModified: Int) {
        let res = try await client.getAll(Self.repoListPath, as: GhRepo.self)
        var next: [String: RepoState] = [:]
        for repo in res.data where !repo.archived && !repo.disabled {
            if var existing = repos[repo.fullName] {
                existing.pushedAt = repo.pushedAt
                next[repo.fullName] = existing
            } else {
                next[repo.fullName] = RepoState(fullName: repo.fullName, pushedAt: repo.pushedAt)
            }
        }
        repos = next
        reposFetchedAt = now()
        return (res.requests, res.notModified)
    }

    private func build() async -> RunsSnapshot {
        let now = now()
        let states = Array(repos.values)
        let runs = states.flatMap(\.runs).sorted { $0.startedAt > $1.startedAt }
        var tiers = Tiers()
        for repo in states {
            switch tier(repo, at: now) {
            case .active: tiers.active += 1
            case .hot: tiers.hot += 1
            case .recent: tiers.recent += 1
            case .quiet: tiers.quiet += 1
            }
        }
        let limitedUntil = await client.rateLimitedUntil.flatMap { $0 > now ? $0 : nil }
        let sync = SyncInfo(
            rateLimit: await client.rateLimit,
            rateLimitedUntil: limitedUntil,
            reposFailed: states.filter { $0.error != nil }.count,
            reposPending: states.filter { $0.checkedAt == nil }.count,
            tiers: tiers,
            lastScan: lastScan,
            warning: warning
        )
        return RunsSnapshot(fetchedAt: lastScanAt ?? now, repoCount: states.count, runs: runs, sync: sync)
    }
}

// MARK: - GitHub wire shapes

private struct GhRepo: Decodable, Sendable {
    var fullName: String
    var archived: Bool
    var disabled: Bool
    var pushedAt: Date?

    enum CodingKeys: String, CodingKey {
        case archived, disabled
        case fullName = "full_name"
        case pushedAt = "pushed_at"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try c.decode(String.self, forKey: .fullName)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        pushedAt = try c.decodeIfPresent(Date.self, forKey: .pushedAt)
    }
}

private struct GhRunsPage: Decodable, Sendable {
    var workflowRuns: [GhWorkflowRun]?

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct GhWorkflowRun: Decodable, Sendable {
    struct Actor: Decodable, Sendable { var login: String }

    var id: Int
    var name: String?
    var displayTitle: String?
    var status: String?
    var conclusion: String?
    var htmlURL: String
    var runStartedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var headBranch: String?
    var event: String?
    var actor: Actor?
    var runNumber: Int

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, event, actor
        case displayTitle = "display_title"
        case htmlURL = "html_url"
        case runStartedAt = "run_started_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case headBranch = "head_branch"
        case runNumber = "run_number"
    }

    func toRun(_ fullName: String) -> WorkflowRun {
        WorkflowRun(
            id: id,
            name: name ?? "",
            displayTitle: displayTitle ?? "",
            status: status ?? "",
            conclusion: conclusion,
            htmlURL: htmlURL,
            runStartedAt: runStartedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            headBranch: headBranch,
            event: event ?? "",
            actorLogin: actor?.login,
            repoFullName: fullName,
            workflowName: name ?? "",
            runNumber: runNumber
        )
    }
}
