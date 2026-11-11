import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { RateLimitInfo } from '../shared/types.ts'

const execFileAsync = promisify(execFile)
const API = 'https://api.github.com'
const TIMEOUT_MS = 15_000

export class GitHubError extends Error {
  status: number
  rateLimited: boolean

  constructor(message: string, status: number, rateLimited = false) {
    super(message)
    this.name = 'GitHubError'
    this.status = status
    this.rateLimited = rateLimited
  }
}

interface CacheEntry {
  etag: string
  body: unknown
  next: string | null
}

export interface GetResult<T> {
  data: T
  /** true when GitHub answered 304 — free, not counted against the rate limit */
  notModified: boolean
  next: string | null
}

function parseNext(link: string | null): string | null {
  if (!link) return null
  const match = link.match(/<([^>]+)>;\s*rel="next"/)
  return match ? match[1] : null
}

/**
 * Minimal GitHub REST client. Borrows the token from the GitHub CLI once,
 * then talks to the API directly so it can use ETags and read rate-limit headers.
 */
export class GitHubClient {
  rateLimit: RateLimitInfo | null = null
  /** epoch ms; requests are refused locally until then */
  rateLimitedUntil = 0

  private token: string | null = null
  private cache = new Map<string, CacheEntry>()

  async get<T>(path: string): Promise<GetResult<T>> {
    if (Date.now() < this.rateLimitedUntil) {
      const at = new Date(this.rateLimitedUntil).toLocaleTimeString('en-GB')
      throw new GitHubError(`GitHub API rate limit reached; it resets at ${at}.`, 403, true)
    }

    const url = path.startsWith('http') ? path : API + path
    const cached = this.cache.get(url)
    const res = await this.request(url, cached?.etag)

    if (res.status === 304 && cached) {
      return { data: cached.body as T, notModified: true, next: cached.next }
    }

    if (!res.ok) {
      const body = (await res.json().catch(() => null)) as { message?: string } | null
      const rateLimited =
        res.status === 429 ||
        (res.status === 403 && res.headers.get('x-ratelimit-remaining') === '0')
      const where = url.replace(API, '')
      throw new GitHubError(
        `GitHub ${res.status} for ${where}: ${body?.message ?? res.statusText}`,
        res.status,
        rateLimited,
      )
    }

    const data = (await res.json()) as T
    const next = parseNext(res.headers.get('link'))
    const etag = res.headers.get('etag')
    if (etag) this.cache.set(url, { etag, body: data, next })
    return { data, notModified: false, next }
  }

  /** Follows `Link: rel="next"` and concatenates array pages. */
  async getAll<T>(path: string): Promise<{ data: T[]; requests: number; notModified: number }> {
    const data: T[] = []
    let url: string | null = path
    let requests = 0
    let notModified = 0
    while (url) {
      const page: GetResult<T[]> = await this.get<T[]>(url)
      requests++
      if (page.notModified) notModified++
      data.push(...page.data)
      url = page.next
    }
    return { data, requests, notModified }
  }

  private async getToken(force = false): Promise<string> {
    if (this.token && !force) return this.token
    try {
      const { stdout } = await execFileAsync('gh', ['auth', 'token'])
      const token = stdout.trim()
      if (!token) throw new Error('empty token')
      this.token = token
      return token
    } catch (err) {
      const e = err as { code?: string; stderr?: string }
      const reason = e.code === 'ENOENT' ? 'GitHub CLI (gh) is not installed.' : e.stderr?.trim()
      throw new GitHubError(
        `Could not get a token from the GitHub CLI. ${reason ?? ''} Run \`gh auth login\`.`.trim(),
        401,
      )
    }
  }

  private async request(url: string, etag: string | undefined, retry = true): Promise<Response> {
    const token = await this.getToken()
    const headers: Record<string, string> = {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'semaforo-local',
    }
    if (etag) headers['If-None-Match'] = etag

    const res = await fetch(url, { headers, signal: AbortSignal.timeout(TIMEOUT_MS) })
    this.track(res)

    if (res.status === 401 && retry) {
      // token may have been rotated by `gh auth refresh`; ask gh again once
      await this.getToken(true)
      return this.request(url, etag, false)
    }
    return res
  }

  private track(res: Response) {
    const limit = Number(res.headers.get('x-ratelimit-limit'))
    const remaining = Number(res.headers.get('x-ratelimit-remaining'))
    const reset = Number(res.headers.get('x-ratelimit-reset'))
    if (limit && Number.isFinite(remaining) && reset) {
      this.rateLimit = { limit, remaining, reset_at: new Date(reset * 1000).toISOString() }
    }

    const exhausted =
      res.status === 429 || (res.status === 403 && res.headers.get('x-ratelimit-remaining') === '0')
    if (exhausted) {
      const retryAfter = Number(res.headers.get('retry-after'))
      this.rateLimitedUntil = retryAfter
        ? Date.now() + retryAfter * 1000
        : reset
          ? reset * 1000
          : Date.now() + 60_000
    }
  }
}
