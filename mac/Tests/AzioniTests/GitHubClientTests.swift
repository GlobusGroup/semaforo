import Foundation
import Testing
@testable import Azioni

@Suite struct GitHubClientTests {
    @Test func parsesNextLink() {
        let link = #"<https://api.github.com/user/repos?page=2>; rel="next", <https://api.github.com/user/repos?page=4>; rel="last""#
        #expect(GitHubClient.parseNext(link)?.absoluteString == "https://api.github.com/user/repos?page=2")
        #expect(GitHubClient.parseNext(#"<https://x/?page=1>; rel="prev""#) == nil)
        #expect(GitHubClient.parseNext(nil) == nil)
    }

    @Test func followsPagesAndRevalidatesWithETags() async throws {
        let fake = FakeGitHub.standardScenario()
        let client = fake.makeClient()

        let first = try await client.getAll(RunStore.repoListPath, as: RepoName.self)
        #expect(first.data.count == 152)
        #expect(first.requests == 2)
        #expect(first.notModified == 0)
        #expect(fake.requests.allSatisfy { $0.authorization == "Bearer test-token" })

        let second = try await client.getAll(RunStore.repoListPath, as: RepoName.self)
        #expect(second.data.map(\.full_name) == first.data.map(\.full_name))
        #expect(second.notModified == 2)
        #expect(fake.requests.suffix(2).allSatisfy { $0.status == 304 && $0.ifNoneMatch != nil })
    }

    @Test func tracksRateLimitHeaders() async throws {
        let fake = FakeGitHub.standardScenario()
        let client = fake.makeClient()
        _ = try await client.get("/repos/org/active-0/actions/runs?per_page=5", as: RunsPage.self)
        let info = try #require(await client.rateLimit)
        #expect(info.limit == 5000)
        #expect(info.remaining == 4999)
        #expect(info.resetAt == fake.resetAt)
    }

    @Test func refusesLocallyUntilReset() async throws {
        let fake = FakeGitHub.standardScenario()
        let client = fake.makeClient()
        let until = fake.clock.now + 600
        fake.rateLimitedUntil = until

        let error = await #expect(throws: GitHubError.self) {
            _ = try await client.get("/repos/org/active-0/actions/runs", as: RunsPage.self)
        }
        #expect(error?.kind == .rateLimited(until: until))
        #expect(await client.rateLimitedUntil == until)
        #expect(fake.requests.count == 1)

        let local = await #expect(throws: GitHubError.self) {
            _ = try await client.get("/repos/org/active-1/actions/runs", as: RunsPage.self)
        }
        #expect(local?.kind == .rateLimited(until: until))
        #expect(fake.requests.count == 1, "no request is sent while rate limited")

        fake.clock.advance(601)
        fake.rateLimitedUntil = nil
        _ = try await client.get("/repos/org/active-1/actions/runs", as: RunsPage.self)
        #expect(fake.requests.count == 2)
    }

    @Test func rereadsTokenOnceOn401() async throws {
        let fake = FakeGitHub.standardScenario()
        fake.validTokens = ["fresh"]
        let token = FakeToken("stale", "fresh")
        let client = fake.makeClient(tokenProvider: token)

        _ = try await client.get("/repos/org/active-0/actions/runs", as: RunsPage.self)
        _ = try await client.get("/repos/org/active-1/actions/runs", as: RunsPage.self)
        #expect(token.calls == [false, true])
        #expect(fake.requests.map(\.status) == [401, 200, 200])
    }

    @Test func persistent401IsNoToken() async throws {
        let fake = FakeGitHub.standardScenario()
        fake.validTokens = []
        let token = FakeToken()
        let client = fake.makeClient(tokenProvider: token)

        let error = await #expect(throws: GitHubError.self) {
            _ = try await client.get("/repos/org/active-0/actions/runs", as: RunsPage.self)
        }
        #expect(error?.kind == .noToken)
        #expect(error?.status == 401)
        #expect(token.calls == [false, true])
    }

    @Test func notFoundIsHTTPError() async throws {
        let fake = FakeGitHub.standardScenario()
        let client = fake.makeClient()
        let error = await #expect(throws: GitHubError.self) {
            _ = try await client.get("/repos/org/quiet-0/actions/runs", as: RunsPage.self)
        }
        #expect(error?.kind == .http)
        #expect(error?.status == 404)
        #expect(error?.message == "GitHub 404 for /repos/org/quiet-0/actions/runs: Not Found")
    }

    @Test func transportFailureIsOffline() async throws {
        let fake = FakeGitHub.standardScenario()
        fake.offline = true
        let client = fake.makeClient()
        let error = await #expect(throws: GitHubError.self) {
            _ = try await client.get("/user/repos", as: [RepoName].self)
        }
        #expect(error?.kind == .offline)
    }
}

@Test func processRunnerCollectsOutput() async throws {
    let ok = try await GhCLIToken.run("/bin/sh", ["-c", "echo token; echo oops >&2"])
    #expect(ok == GhCLIToken.ProcessResult(status: 0, stdout: "token\n", stderr: "oops\n"))
    let missing = try await GhCLIToken.run("/bin/zsh", ["-fc", "definitely-not-a-command-azioni"])
    #expect(missing.status == 127)
}

private struct RepoName: Decodable, Sendable { var full_name: String }
private struct RunsPage: Decodable, Sendable { var total_count: Int }
