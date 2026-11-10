import type { RunsResponse, WorkflowRun } from '../shared/types.ts'
import { GitHubClient, GitHubError } from './github.ts'

const CONCURRENCY = 8
const RUNS_PER_REPO = 5
/** How long the repo list is reused before asking GitHub again. */
const REPO_LIST_TTL = 10 * 60_000
/** Requests closer together than this share the previous scan. */
const MIN_SCAN_GAP = 10_000
/** Repos pushed to (or with a run) within this window poll more often. */
const RECENT_WINDOW = 7 * 24 * 60 * 60_000
/** When the hourly budget drops below this, only repos with live runs are polled. */
const LOW_BUDGET = 500

const INTERVAL = {
  active: 20_000, // a run is queued or in progress
  recent: 90_000, // pushed or ran recently
  quiet: 15 * 60_000, // catches scheduled / manual runs on idle repos
} as const

type Tier = keyof typeof INTERVAL

interface GhRepo {
  full_name: string
  archived: boolean
  disabled: boolean
  pushed_at: string | null
}

interface GhWorkflowRun {
  id: number
  name: string
  display_title: string
  status: string
  conclusion: string | null
  html_url: string
  run_started_at: string | null
  created_at: string
  updated_at: string
  head_branch: string | null
  event: string
  actor: { login: string } | null
  run_number: number
}

interface RepoState {
  fullName: string
  pushedAt: number
  runs: WorkflowRun[]
  /** epoch ms of the last completed check; 0 = never */
  checkedAt: number
  error: string | null
}

const ACTIVE_STATUSES = new Set(['queued', 'in_progress', 'waiting', 'requested', 'pending'])

function startedAt(run: WorkflowRun): number {
  return new Date(run.run_started_at || run.created_at).getTime()
}

function toRun(fullName: string, run: GhWorkflowRun): WorkflowRun {
  return {
    id: run.id,
    name: run.name,
    display_title: run.display_title,
    status: run.status,
    conclusion: run.conclusion,
    html_url: run.html_url,
    run_started_at: run.run_started_at,
    created_at: run.created_at,
    updated_at: run.updated_at,
    head_branch: run.head_branch,
    event: run.event,
    actor_login: run.actor?.login ?? null,
    repo_full_name: fullName,
    workflow_name: run.name,
    run_number: run.run_number,
  }
}

async function mapPool<T>(items: T[], limit: number, fn: (item: T) => Promise<void>) {
  let next = 0
  async function worker() {
    while (next < items.length) await fn(items[next++])
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))
}

/**
 * Shared, in-memory view of workflow runs. Every browser tab reads the same
 * snapshot; concurrent requests join one in-flight scan; each scan only asks
 * GitHub about repos whose tier interval has elapsed.
 */
export class RunStore {
  private gh = new GitHubClient()
  private repos = new Map<string, RepoState>()
  private reposFetchedAt = 0
  private lastScanAt = 0
  private inflight: Promise<void> | null = null
  private warning: string | null = null
  /** set when a scan could not produce any data at all (e.g. no token, first repo list failed) */
  private failure: Error | null = null
  private lastScan = { repos_checked: 0, requests: 0, not_modified: 0 }

  async snapshot(force = false): Promise<RunsResponse> {
    // With no data yet, retry on every request; GitHubClient short-circuits while rate limited.
    const stale = this.failure !== null || Date.now() - this.lastScanAt >= MIN_SCAN_GAP
    if (!this.inflight && (force || stale)) {
      this.inflight = this.scan(force).finally(() => {
        this.lastScanAt = Date.now()
        this.inflight = null
      })
    }
    if (this.inflight) await this.inflight
    if (this.failure) throw this.failure
    return this.build()
  }

  private tier(repo: RepoState, now: number): Tier {
    if (repo.runs.some((r) => ACTIVE_STATUSES.has(r.status))) return 'active'
    const latestRun = repo.runs.length ? Math.max(...repo.runs.map(startedAt)) : 0
    if (now - Math.max(repo.pushedAt, latestRun) < RECENT_WINDOW) return 'recent'
    return 'quiet'
  }

  private isDue(repo: RepoState, now: number, force: boolean, lowBudget: boolean): boolean {
    if (repo.checkedAt === 0) return true
    const tier = this.tier(repo, now)
    if (lowBudget && tier !== 'active') return false
    if (force && tier !== 'quiet') return true
    return now - repo.checkedAt >= INTERVAL[tier]
  }

  private async scan(force: boolean) {
    const now = Date.now()
    this.warning = null
    this.failure = null
    let requests = 0
    let notModified = 0

    if (this.repos.size === 0 || now - this.reposFetchedAt >= REPO_LIST_TTL) {
      try {
        const res = await this.refreshRepos()
        requests += res.requests
        notModified += res.notModified
      } catch (err) {
        if (this.repos.size === 0) {
          this.failure = err as Error
          return
        }
        this.warning = `Repo list refresh failed: ${(err as Error).message}`
      }
    }

    const lowBudget = (this.gh.rateLimit?.remaining ?? Infinity) < LOW_BUDGET
    const due = [...this.repos.values()].filter((r) => this.isDue(r, now, force, lowBudget))

    await mapPool(due, CONCURRENCY, async (repo) => {
      try {
        const res = await this.gh.get<{ workflow_runs?: GhWorkflowRun[] }>(
          `/repos/${repo.fullName}/actions/runs?per_page=${RUNS_PER_REPO}`,
        )
        requests++
        if (res.notModified) notModified++
        repo.runs = (res.data.workflow_runs ?? []).map((run) => toRun(repo.fullName, run))
        repo.error = null
      } catch (err) {
        const e = err as GitHubError
        if (e.rateLimited) return // leave checkedAt alone so it is retried once the limit resets
        requests++
        if (e.status === 404) {
          repo.runs = []
          repo.error = null
        } else {
          repo.error = e.message
          console.warn(`[azioni] ${repo.fullName}:`, e.message)
        }
      }
      repo.checkedAt = Date.now()
    })

    this.lastScan = { repos_checked: due.length, requests, not_modified: notModified }
  }

  private async refreshRepos() {
    const res = await this.gh.getAll<GhRepo>(
      '/user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=pushed',
    )
    const next = new Map<string, RepoState>()
    for (const repo of res.data) {
      if (repo.archived || repo.disabled) continue
      const existing = this.repos.get(repo.full_name)
      const pushedAt = repo.pushed_at ? new Date(repo.pushed_at).getTime() : 0
      next.set(
        repo.full_name,
        existing
          ? { ...existing, pushedAt }
          : { fullName: repo.full_name, pushedAt, runs: [], checkedAt: 0, error: null },
      )
    }
    this.repos = next
    this.reposFetchedAt = Date.now()
    return res
  }

  private build(): RunsResponse {
    const repos = [...this.repos.values()]
    const runs = repos.flatMap((r) => r.runs).sort((a, b) => startedAt(b) - startedAt(a))
    const limitedUntil = this.gh.rateLimitedUntil > Date.now() ? this.gh.rateLimitedUntil : 0
    const now = Date.now()
    const tiers = { active: 0, recent: 0, quiet: 0 }
    for (const repo of repos) tiers[this.tier(repo, now)]++

    return {
      fetched_at: new Date(this.lastScanAt || now).toISOString(),
      repo_count: repos.length,
      runs,
      sync: {
        rate_limit: this.gh.rateLimit,
        rate_limited_until: limitedUntil ? new Date(limitedUntil).toISOString() : null,
        repos_failed: repos.filter((r) => r.error).length,
        repos_pending: repos.filter((r) => r.checkedAt === 0).length,
        tiers,
        last_scan: this.lastScan,
        warning: this.warning,
      },
    }
  }
}
