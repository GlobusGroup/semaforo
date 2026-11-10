import type { RunConclusion, RunStatus, WorkflowRun } from '../types'

export type SignalKind = 'running' | 'queued' | 'success' | 'failure' | 'cancelled' | 'neutral'

export function signalOf(run: WorkflowRun): SignalKind {
  const status = run.status as RunStatus
  const conclusion = run.conclusion as RunConclusion

  if (status === 'in_progress' || status === 'waiting' || status === 'requested') {
    return 'running'
  }
  if (status === 'queued' || status === 'pending') {
    return 'queued'
  }
  if (conclusion === 'success') return 'success'
  if (conclusion === 'failure' || conclusion === 'timed_out' || conclusion === 'action_required') {
    return 'failure'
  }
  if (conclusion === 'cancelled' || conclusion === 'skipped' || conclusion === 'stale') {
    return 'cancelled'
  }
  return 'neutral'
}

export function signalLabel(kind: SignalKind): string {
  switch (kind) {
    case 'running':
      return 'Running'
    case 'queued':
      return 'Queued'
    case 'success':
      return 'Passed'
    case 'failure':
      return 'Failed'
    case 'cancelled':
      return 'Stopped'
    default:
      return 'Idle'
  }
}

export function countBySignal(runs: WorkflowRun[]): Record<SignalKind, number> {
  const counts: Record<SignalKind, number> = {
    running: 0,
    queued: 0,
    success: 0,
    failure: 0,
    cancelled: 0,
    neutral: 0,
  }
  for (const run of runs) {
    counts[signalOf(run)]++
  }
  return counts
}
