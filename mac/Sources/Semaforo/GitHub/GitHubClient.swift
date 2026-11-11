import Foundation

struct GetResult<T: Sendable>: Sendable {
    var data: T
    /// true when GitHub answered 304 (free).
    var notModified: Bool
    var next: URL?
}

/// GitHub REST client.
///
/// Borrows the token from the GitHub CLI once, then talks to the API directly so it
/// can use ETags (304s are free) and read the rate-limit headers.
actor GitHubClient {
    static let defaultBaseURL = URL(string: "https://api.github.com")!
    static let timeout: TimeInterval = 15

    private(set) var rateLimit: RateLimitInfo?
    /// Requests are refused locally until then.
    private(set) var rateLimitedUntil: Date?

    private let session: URLSession
    private let tokenProvider: any TokenProvider
    private let baseURL: String
    private let now: @Sendable () -> Date
    private var token: String?
    private var cache: [String: CacheEntry] = [:]

    private struct CacheEntry {
        var etag: String
        var body: Data
        var next: URL?
    }

    init(
        session: URLSession = .shared,
        tokenProvider: any TokenProvider = GhCLIToken(),
        baseURL: URL = GitHubClient.defaultBaseURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base
        self.now = now
    }

    /// `path` is either "/repos/..." (relative to baseURL) or an absolute URL string.
    func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> GetResult<T> {
        if let until = rateLimitedUntil, now() < until {
            throw GitHubError(
                message: "GitHub API rate limit reached; it resets at \(Self.clockTime(until)).",
                status: 403,
                kind: .rateLimited(until: until)
            )
        }

        let urlString = path.hasPrefix("http") ? path : baseURL + path
        guard let url = URL(string: urlString) else {
            throw GitHubError(message: "Invalid GitHub URL: \(urlString)", status: 0, kind: .http)
        }
        let cached = cache[urlString]
        let (body, response) = try await request(url, etag: cached?.etag)

        if response.statusCode == 304, let cached {
            return GetResult(data: try decode(T.self, from: cached.body, status: 304, where: path),
                             notModified: true, next: cached.next)
        }

        guard (200..<300).contains(response.statusCode) else {
            let status = response.statusCode
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            let text = "GitHub \(status) for \(shortPath(urlString)): \(message)"
            let kind: GitHubError.Kind
            if Self.isExhausted(response) {
                kind = .rateLimited(until: rateLimitedUntil)
            } else if status == 401 {
                kind = .noToken
            } else {
                kind = .http
            }
            throw GitHubError(message: text, status: status, kind: kind)
        }

        let data = try decode(T.self, from: body, status: response.statusCode, where: path)
        let next = Self.parseNext(response.value(forHTTPHeaderField: "Link"))
        if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
            cache[urlString] = CacheEntry(etag: etag, body: body, next: next)
        }
        return GetResult(data: data, notModified: false, next: next)
    }

    /// Follows `Link: rel="next"` and concatenates array pages.
    func getAll<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> (data: [T], requests: Int, notModified: Int) {
        var data: [T] = []
        var url: String? = path
        var requests = 0
        var notModified = 0
        while let current = url {
            let page = try await get(current, as: [T].self)
            requests += 1
            if page.notModified { notModified += 1 }
            data.append(contentsOf: page.data)
            url = page.next?.absoluteString
        }
        return (data, requests, notModified)
    }

    // MARK: - Internals

    private struct ErrorBody: Decodable { var message: String? }

    private func shortPath(_ url: String) -> String {
        url.hasPrefix(baseURL) ? String(url.dropFirst(baseURL.count)) : url
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, status: Int, where path: String) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError(message: "Unexpected GitHub response for \(shortPath(path)): \(error)",
                              status: status, kind: .http)
        }
    }

    private func getToken(force: Bool = false) async throws -> String {
        if let token, !force { return token }
        let fresh = try await tokenProvider.token(force: force)
        token = fresh
        return fresh
    }

    private func request(_ url: URL, etag: String?, retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let token = try await getToken()
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("semaforo-mac", forHTTPHeaderField: "User-Agent")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            throw GitHubError(message: "Can't reach GitHub: \(error.localizedDescription)", status: 0, kind: .offline)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError(message: "Unexpected non-HTTP response from GitHub", status: 0, kind: .http)
        }
        track(http)

        if http.statusCode == 401 && retry {
            // token may have been rotated by `gh auth refresh`; ask gh again once
            _ = try await getToken(force: true)
            return try await request(url, etag: etag, retry: false)
        }
        return (data, http)
    }

    private func track(_ res: HTTPURLResponse) {
        let limit = Int(res.value(forHTTPHeaderField: "x-ratelimit-limit") ?? "") ?? 0
        let remaining = Int(res.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "")
        let reset = Double(res.value(forHTTPHeaderField: "x-ratelimit-reset") ?? "") ?? 0
        if limit > 0, let remaining, reset > 0 {
            rateLimit = RateLimitInfo(limit: limit, remaining: remaining,
                                      resetAt: Date(timeIntervalSince1970: reset))
        }

        if Self.isExhausted(res) {
            let retryAfter = Double(res.value(forHTTPHeaderField: "retry-after") ?? "") ?? 0
            if retryAfter > 0 {
                rateLimitedUntil = now().addingTimeInterval(retryAfter)
            } else if reset > 0 {
                rateLimitedUntil = Date(timeIntervalSince1970: reset)
            } else {
                rateLimitedUntil = now().addingTimeInterval(60)
            }
        }
    }

    private static func isExhausted(_ res: HTTPURLResponse) -> Bool {
        res.statusCode == 429
            || (res.statusCode == 403 && res.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0")
    }

    static func parseNext(_ link: String?) -> URL? {
        // Same as the server's /<([^>]+)>;\s*rel="next"/ (URLs may contain commas).
        guard let link,
              let match = nextLinkPattern.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)),
              let range = Range(match.range(at: 1), in: link) else { return nil }
        return URL(string: String(link[range]))
    }

    private static let nextLinkPattern = try! NSRegularExpression(pattern: #"<([^>]+)>;\s*rel="next""#)

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
