import Foundation
import Testing
@testable import Azioni

@Suite struct RunStoreTests {
    @Test func firstScanTiersAndCounts() async throws {
        let fake = FakeGitHub.standardScenario()
        let store = fake.makeStore()

        let snap = try await store.scan()
        #expect(snap.repoCount == 152)
        #expect(snap.sync.tiers == Tiers(active: 3, recent: 12, quiet: 137))
        #expect(snap.sync.lastScan == ScanStats(reposChecked: 152, requests: 154, notModified: 0))
        #expect(snap.sync.reposPending == 0)
        #expect(snap.sync.reposFailed == 0, "404 on actions/runs means no runs, not a failure")
        #expect(snap.sync.rateLimitedUntil == nil)
        #expect(snap.sync.warning == nil)
        #expect(fake.remaining == 5000 - 154)
        // headers of the last response to arrive; with 8 in flight that may not be the lowest
        let remaining = try #require(snap.sync.rateLimit?.remaining)
        #expect((5000 - 154)...(5000 - 154 + RunStore.concurrency) ~= remaining)
        // 3 active × 2 + 12 recent + every third quiet repo except quiet-0 (45)
        #expect(snap.runs.count == 63)
        #expect(snap.runs == snap.runs.sorted { $0.startedAt > $1.startedAt })
        let newest = try #require(snap.runs.first)
        #expect(newest.status == "in_progress")
        #expect(newest.repoFullName.hasPrefix("org/active-"))
        #expect(newest.actorLogin == "octocat")
        #expect(newest.workflowName == "CI")
    }

    @Test func fullScenario() async throws {
        let fake = FakeGitHub.standardScenario()
        let store = fake.makeStore()
        let first = try await store.scan()

        // Second forced scan, past the repo-list TTL: everything revalidates with ETags.
        fake.clock.advance(11 * 60)
        fake.updateRepo("org/active-0") { repo in
            repo.runs[0]["status"] = "completed"
            repo.runs[0]["conclusion"] = "success"
        }
        let second = try await store.scan(force: true)
        #expect(second.sync.lastScan == ScanStats(reposChecked: 15, requests: 17, notModified: 16))
        #expect(second.sync.tiers == Tiers(active: 2, recent: 13, quiet: 137))
        #expect(second.runs.count == first.runs.count)

        // Rate-limit phase: GitHub answers 403 + remaining 0; cached runs are still served.
        let until = fake.clock.now + 30 * 60
        fake.rateLimitedUntil = until
        fake.clock.advance(30)
        let limited = try await store.scan(force: true)
        #expect(limited.sync.rateLimitedUntil == until)
        #expect(limited.runs == second.runs)
        #expect(limited.sync.reposFailed == 0)
        #expect(limited.sync.lastScan.requests == 0, "rate-limited checks are not counted")
        let sentWhileLimited = fake.requests.count

        fake.clock.advance(60)
        let stillLimited = try await store.scan(force: true)
        #expect(fake.requests.count == sentWhileLimited, "no requests until the reset")
        #expect(stillLimited.runs == second.runs)
        #expect(stillLimited.sync.rateLimitedUntil == until)

        // After the reset, polling resumes.
        fake.clock.advance(30 * 60)
        fake.rateLimitedUntil = nil
        let resumed = try await store.scan(force: true)
        #expect(resumed.sync.rateLimitedUntil == nil)
        #expect(resumed.sync.lastScan.requests > 0)
        #expect(fake.requests.count > sentWhileLimited)
        #expect(resumed.runs.count == first.runs.count)
    }

    @Test func unforcedScanOnlyChecksDueRepos() async throws {
        let fake = FakeGitHub.standardScenario()
        let store = fake.makeStore()
        _ = try await store.scan()

        fake.clock.advance(5)
        #expect(try await store.scan().sync.lastScan.reposChecked == 0)
        fake.clock.advance(20)
        #expect(try await store.scan().sync.lastScan.reposChecked == 3) // active only
        fake.clock.advance(90)
        #expect(try await store.scan().sync.lastScan.reposChecked == 15) // active + recent
    }

    @Test func lowBudgetPollsOnlyActiveRepos() async throws {
        let fake = FakeGitHub.standardScenario()
        fake.remaining = 400
        let store = fake.makeStore()
        _ = try await store.scan()
        fake.clock.advance(15 * 60 + 1)
        let snap = try await store.scan(force: true)
        #expect(snap.sync.lastScan.reposChecked == 3)
    }

    @Test func concurrentScansJoin() async throws {
        let fake = FakeGitHub.standardScenario()
        let store = fake.makeStore()
        async let a = store.scan()
        async let b = store.scan(force: true)
        let (x, y) = try await (a, b)
        #expect(fake.requests.count == 154)
        #expect(x == y)
    }

    @Test func rereadsTokenOnceOn401() async throws {
        let fake = FakeGitHub.standardScenario()
        fake.validTokens = ["fresh"]
        let token = FakeToken("stale", "fresh")
        let store = fake.makeStore(tokenProvider: token)
        let snap = try await store.scan()
        #expect(snap.repoCount == 152)
        #expect(token.calls == [false, true])
        #expect(fake.requests.filter { $0.status == 401 }.count == 1)
    }

    @Test func throwsWithoutAnyData() async throws {
        let fake = FakeGitHub.standardScenario()
        let noToken = GitHubError(message: "Could not get a token", status: 401, kind: .noToken)
        let store = fake.makeStore(tokenProvider: FakeToken(error: noToken))
        let error = await #expect(throws: GitHubError.self) { _ = try await store.scan() }
        #expect(error?.kind == .noToken)
        #expect(fake.requests.isEmpty)

        let rejected = FakeGitHub.standardScenario()
        rejected.validTokens = []
        let error401 = await #expect(throws: GitHubError.self) { _ = try await rejected.makeStore().scan() }
        #expect(error401?.kind == .noToken)
    }

    @Test func offlineFirstLoadThrowsLaterLoadWarns() async throws {
        let fake = FakeGitHub.standardScenario()
        let store = fake.makeStore()
        fake.offline = true
        let error = await #expect(throws: GitHubError.self) { _ = try await store.scan() }
        #expect(error?.kind == .offline)

        fake.offline = false
        let ok = try await store.scan()
        fake.offline = true
        fake.clock.advance(11 * 60)
        let snap = try await store.scan()
        #expect(snap.sync.warning?.hasPrefix("Repo list refresh failed:") == true)
        #expect(snap.sync.reposFailed == 15)
        #expect(snap.runs == ok.runs)
    }

    @Test func dropsArchivedRepos() async throws {
        let fake = FakeGitHub.standardScenario()
        fake.updateRepo("org/quiet-5") { $0.archived = true }
        let snap = try await fake.makeStore().scan()
        #expect(snap.repoCount == 151)
    }
}
