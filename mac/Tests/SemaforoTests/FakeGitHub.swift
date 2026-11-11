import Foundation
@testable import Semaforo

/// A thread-safe, manually advanced clock shared by the fake server and the code under test.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    /// Pass this as `now:` to GitHubClient / RunStore / BoardModel.
    var provider: @Sendable () -> Date { { self.now } }
}

/// Token provider for tests: returns `tokens[n]` on the n-th call (last one repeats).
final class FakeToken: TokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let tokens: [String]
    private var index = 0
    private var _calls: [Bool] = []
    private let error: GitHubError?

    init(_ tokens: String..., error: GitHubError? = nil) {
        self.tokens = tokens.isEmpty ? ["test-token"] : tokens
        self.error = error
    }

    /// `force` flag of each call, in order.
    var calls: [Bool] { lock.withLock { _calls } }

    func token(force: Bool) async throws -> String {
        try lock.withLock {
            _calls.append(force)
            if let error { throw error }
            let token = tokens[min(index, tokens.count - 1)]
            index += 1
            return token
        }
    }
}

/// An in-memory GitHub REST API served through a `URLProtocol` stub.
///
/// Each instance gets its own random host, so tests can run in parallel: the
/// protocol looks the fake up by `request.url.host`.
///
///     let fake = FakeGitHub.standardScenario()
///     let store = fake.makeStore()
///     let snapshot = try await store.scan()
final class FakeGitHub: @unchecked Sendable {
    struct Repo {
        var fullName: String
        var pushedAt: Date?
        var archived = false
        /// GitHub JSON objects for `workflow_runs`.
        var runs: [[String: Any]] = []
        /// actions/runs answers 404 (Actions disabled / no access).
        var runsNotFound = false
    }

    struct Request: Sendable {
        var path: String
        var query: String?
        var status: Int
        var authorization: String?
        var ifNoneMatch: String?
    }

    let host: String
    let clock: FakeClock
    var baseURL: URL { URL(string: "https://\(host)")! }

    private let lock = NSLock()
    private var _repos: [Repo] = []
    private var _requests: [Request] = []
    private var _validTokens: Set<String> = ["test-token"]
    private var _remaining = 5000
    private var _rateLimitedUntil: Date?
    private var _offline = false
    let limit = 5000
    let pageSize = 100

    init(clock: FakeClock = FakeClock(), repos: [Repo] = []) {
        self.host = "gh-\(UUID().uuidString.lowercased()).fake"
        self.clock = clock
        self._repos = repos
        FakeGitHubProtocol.register(self)
    }

    deinit { FakeGitHubProtocol.unregister(host) }

    // MARK: State (thread-safe)

    var repos: [Repo] {
        get { lock.withLock { _repos } }
        set { lock.withLock { _repos = newValue } }
    }

    func updateRepo(_ fullName: String, _ change: (inout Repo) -> Void) {
        lock.withLock {
            if let i = _repos.firstIndex(where: { $0.fullName == fullName }) { change(&_repos[i]) }
        }
    }

    /// Every request received, in order.
    var requests: [Request] { lock.withLock { _requests } }
    var validTokens: Set<String> {
        get { lock.withLock { _validTokens } }
        set { lock.withLock { _validTokens = newValue } }
    }
    var remaining: Int {
        get { lock.withLock { _remaining } }
        set { lock.withLock { _remaining = newValue } }
    }
    /// While set and in the future, every request gets 403 with `x-ratelimit-remaining: 0`.
    var rateLimitedUntil: Date? {
        get { lock.withLock { _rateLimitedUntil } }
        set { lock.withLock { _rateLimitedUntil = newValue } }
    }
    /// Fails every request with `URLError.notConnectedToInternet`.
    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    /// Reset time reported in `x-ratelimit-reset`: the rate-limit end, else the top of the next hour plus one.
    var resetAt: Date { lock.withLock { resetAtLocked } }

    // MARK: Wiring

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGitHubProtocol.self]
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    func makeClient(tokenProvider: any TokenProvider = FakeToken()) -> GitHubClient {
        GitHubClient(session: makeSession(), tokenProvider: tokenProvider, baseURL: baseURL, now: clock.provider)
    }

    /// A `RunStore` backed by this fake, sharing its clock.
    func makeStore(tokenProvider: any TokenProvider = FakeToken()) -> RunStore {
        RunStore(client: makeClient(tokenProvider: tokenProvider), now: clock.provider)
    }

    // MARK: Request handling

    enum Reply {
        case response(HTTPURLResponse, Data)
        case failure(URLError)
    }

    func handle(_ request: URLRequest) -> Reply {
        lock.withLock { handleLocked(request) }
    }

    private func handleLocked(_ request: URLRequest) -> Reply {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let auth = request.value(forHTTPHeaderField: "Authorization")
        let ifNoneMatch = request.value(forHTTPHeaderField: "If-None-Match")

        if _offline { return .failure(URLError(.notConnectedToInternet)) }

        func reply(_ status: Int, _ body: Any?, headers extra: [String: String] = [:]) -> Reply {
            _requests.append(Request(path: components.path, query: components.query, status: status,
                                     authorization: auth, ifNoneMatch: ifNoneMatch))
            // authenticated, non-304 answers count against the budget (404s too, as on GitHub)
            if status != 304, status != 401, extra["x-ratelimit-remaining"] == nil {
                _remaining = max(0, _remaining - 1)
            }
            var headers = extra
            headers["Content-Type"] = "application/json; charset=utf-8"
            headers["x-ratelimit-limit"] = String(limit)
            headers["x-ratelimit-remaining"] = headers["x-ratelimit-remaining"] ?? String(_remaining)
            headers["x-ratelimit-reset"] = String(Int(resetAtLocked.timeIntervalSince1970))
            let data = body.map { try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return .response(response, data)
        }

        if let until = _rateLimitedUntil, clock.now < until {
            return reply(403, ["message": "API rate limit exceeded"], headers: ["x-ratelimit-remaining": "0"])
        }

        guard let auth, auth.hasPrefix("Bearer "), _validTokens.contains(String(auth.dropFirst(7))) else {
            return reply(401, ["message": "Bad credentials"])
        }

        // Body + ETag for a successful GET; a matching If-None-Match yields a free 304.
        func ok(_ body: Any, link: String? = nil) -> Reply {
            let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let etag = "W/\"\(Self.hash(data))\""
            var headers = ["ETag": etag]
            if let link { headers["Link"] = link }
            if ifNoneMatch == etag { return reply(304, nil, headers: headers) }
            return reply(200, body, headers: headers)
        }

        let path = components.path
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        if path == "/user/repos" {
            let page = Int(query["page"] ?? "1") ?? 1
            let perPage = Int(query["per_page"] ?? "30") ?? 30
            let start = (page - 1) * perPage
            let slice = _repos.dropFirst(start).prefix(perPage)
            let body = slice.map { repo -> [String: Any] in
                [
                    "full_name": repo.fullName,
                    "archived": repo.archived,
                    "disabled": false,
                    "pushed_at": repo.pushedAt.map(Self.iso) ?? NSNull(),
                ]
            }
            var link: String?
            if start + perPage < _repos.count {
                var next = components
                var items = (components.queryItems ?? []).filter { $0.name != "page" }
                items.append(URLQueryItem(name: "page", value: String(page + 1)))
                next.queryItems = items
                link = "<\(next.url!.absoluteString)>; rel=\"next\", <\(next.url!.absoluteString)>; rel=\"last\""
            }
            return ok(body, link: link)
        }

        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 5, parts[0] == "repos", parts[3] == "actions", parts[4] == "runs" {
            let fullName = "\(parts[1])/\(parts[2])"
            guard let repo = _repos.first(where: { $0.fullName == fullName }), !repo.runsNotFound else {
                return reply(404, ["message": "Not Found"])
            }
            let perPage = Int(query["per_page"] ?? "30") ?? 30
            return ok(["total_count": repo.runs.count, "workflow_runs": Array(repo.runs.prefix(perPage))])
        }

        return reply(404, ["message": "Not Found"])
    }

    private var resetAtLocked: Date {
        if let until = _rateLimitedUntil { return until }
        return Date(timeIntervalSince1970: (clock.now.timeIntervalSince1970 / 3600).rounded(.up) * 3600 + 3600)
    }

    // MARK: Fixtures

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func hash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for byte in data { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    /// A GitHub-shaped workflow run object.
    static func run(
        id: Int,
        repo: String,
        status: String = "completed",
        conclusion: String? = "success",
        startedAt: Date,
        name: String = "CI",
        actor: String = "octocat"
    ) -> [String: Any] {
        [
            "id": id,
            "name": name,
            "display_title": "Commit \(id)",
            "status": status,
            "conclusion": conclusion ?? NSNull(),
            "html_url": "https://github.com/\(repo)/actions/runs/\(id)",
            "run_started_at": iso(startedAt),
            "created_at": iso(startedAt),
            "updated_at": iso(startedAt.addingTimeInterval(60)),
            "head_branch": "main",
            "event": "push",
            "actor": ["login": actor],
            "run_number": id % 1000,
        ]
    }

    /// The web server's scenario: 152 repos over 2 pages of /user/repos.
    /// - `org/active-0...2`: an in-progress run (tier active)
    /// - `org/recent-0...11`: pushed within 7 days, completed runs (tier recent)
    /// - `org/quiet-0...136`: pushed 60 days ago (tier quiet); `org/quiet-0` answers 404 on actions/runs
    static func standardScenario(clock: FakeClock = FakeClock()) -> FakeGitHub {
        let now = clock.now
        let day: TimeInterval = 24 * 60 * 60
        var repos: [Repo] = []
        var id = 1000
        func nextID() -> Int { id += 1; return id }

        for i in 0..<3 {
            let name = "org/active-\(i)"
            repos.append(Repo(fullName: name, pushedAt: now - 600, runs: [
                run(id: nextID(), repo: name, status: "in_progress", conclusion: nil, startedAt: now - 120),
                run(id: nextID(), repo: name, startedAt: now - day),
            ]))
        }
        for i in 0..<12 {
            let name = "org/recent-\(i)"
            let conclusion = i == 0 ? "failure" : "success"
            repos.append(Repo(fullName: name, pushedAt: now - Double(i + 1) * 3 * 3600, runs: [
                run(id: nextID(), repo: name, conclusion: conclusion, startedAt: now - Double(i + 1) * 3 * 3600),
            ]))
        }
        for i in 0..<137 {
            let name = "org/quiet-\(i)"
            var repo = Repo(fullName: name, pushedAt: now - 60 * day)
            if i == 0 {
                repo.runsNotFound = true
            } else if i % 3 == 0 {
                repo.runs = [run(id: nextID(), repo: name, startedAt: now - 60 * day)]
            }
            repos.append(repo)
        }
        // /user/repos?sort=pushed: newest push first
        repos.sort { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
        return FakeGitHub(clock: clock, repos: repos)
    }
}

/// Routes requests to the `FakeGitHub` registered for the request's host.
final class FakeGitHubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var fakes: [String: Weak] = [:]
    private static let lock = NSLock()

    private struct Weak { weak var fake: FakeGitHub? }

    static func register(_ fake: FakeGitHub) { lock.withLock { fakes[fake.host] = Weak(fake: fake) } }
    static func unregister(_ host: String) { _ = lock.withLock { fakes.removeValue(forKey: host) } }
    static func fake(for host: String?) -> FakeGitHub? {
        guard let host else { return nil }
        return lock.withLock { fakes[host]?.fake }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".fake") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fake = Self.fake(for: request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch fake.handle(request) {
        case let .response(response, data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
