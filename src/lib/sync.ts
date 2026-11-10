import type { SyncInfo } from '../types'
import { relativeTime } from './format'

/** One line about sync health, or null when everything is fine. */
export function syncNotice(sync: SyncInfo, now: number): string | null {
  if (sync.rate_limited_until) {
    return `GitHub rate limit reached — showing cached runs until it resets ${relativeTime(sync.rate_limited_until, now)}.`
  }
  const parts: string[] = []
  if (sync.repos_pending > 0) parts.push(`${sync.repos_pending} repos still loading`)
  if (sync.rate_limit && sync.rate_limit.remaining < 500) {
    parts.push(
      `API budget low (${sync.rate_limit.remaining}/${sync.rate_limit.limit}), only live runs are polled`,
    )
  }
  if (sync.repos_failed > 0) parts.push(`${sync.repos_failed} repos failed to load`)
  if (sync.warning) parts.push(sync.warning)
  return parts.length ? `${parts.join(' · ')}.` : null
}
