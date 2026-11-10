export type RunStatus = 'queued' | 'in_progress' | 'completed' | 'waiting' | 'requested' | 'pending' | string

export type RunConclusion =
  | 'success'
  | 'failure'
  | 'cancelled'
  | 'skipped'
  | 'timed_out'
  | 'action_required'
  | 'neutral'
  | 'stale'
  | null
  | string

export interface WorkflowRun {
  id: number
  name: string
  display_title: string
  status: RunStatus
  conclusion: RunConclusion
  html_url: string
  run_started_at: string | null
  created_at: string
  updated_at: string
  head_branch: string | null
  event: string
  actor_login: string | null
  repo_full_name: string
  workflow_name: string
  run_number: number
}

export interface RateLimitInfo {
  limit: number
  remaining: number
  reset_at: string
}

export interface SyncInfo {
  rate_limit: RateLimitInfo | null
  /** set while GitHub is refusing requests; cached runs are still served */
  rate_limited_until: string | null
  repos_failed: number
  /** repos not checked yet (first load still filling in) */
  repos_pending: number
  tiers: { active: number; recent: number; quiet: number }
  last_scan: { repos_checked: number; requests: number; not_modified: number }
  warning: string | null
}

export interface RunsResponse {
  fetched_at: string
  repo_count: number
  runs: WorkflowRun[]
  sync: SyncInfo
}

export interface ApiErrorBody {
  error: string
  detail?: string
}
