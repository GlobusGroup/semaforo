import type { WorkflowRun } from '../types'
import { absoluteTime, relativeTime } from '../lib/format'
import { signalOf } from '../lib/status'
import { StatusMark } from './StatusMark'

interface RunTableProps {
  runs: WorkflowRun[]
  now: number
}

export function RunTable({ runs, now }: RunTableProps) {
  if (runs.length === 0) {
    return (
      <div className="empty-state" role="status">
        <p className="empty-state__title">No runs match this signal</p>
        <p className="empty-state__body">
          Try “All”, or wait for the next workflow to start in one of your repos.
        </p>
      </div>
    )
  }

  return (
    <div className="run-table-wrap">
      <table className="run-table">
        <caption className="visually-hidden">
          GitHub Actions workflow runs sorted by start time
        </caption>
        <thead>
          <tr>
            <th scope="col">Status</th>
            <th scope="col">Repository</th>
            <th scope="col">Workflow</th>
            <th scope="col">Branch</th>
            <th scope="col">Started</th>
            <th scope="col">
              <span className="visually-hidden">Open run</span>
            </th>
          </tr>
        </thead>
        <tbody>
          {runs.map((run) => {
            const kind = signalOf(run)
            const started = run.run_started_at || run.created_at
            return (
              <tr key={`${run.repo_full_name}-${run.id}`} className={`run-row run-row--${kind}`}>
                <td>
                  <StatusMark kind={kind} />
                </td>
                <td>
                  <span className="run-repo">{run.repo_full_name}</span>
                  {run.actor_login ? (
                    <span className="run-actor">@{run.actor_login}</span>
                  ) : null}
                </td>
                <td>
                  <span className="run-workflow">{run.workflow_name}</span>
                  <span className="run-title">{run.display_title}</span>
                </td>
                <td>
                  <span className="run-branch">{run.head_branch || '—'}</span>
                  <span className="run-event">{run.event}</span>
                </td>
                <td>
                  <time className="run-started" dateTime={started} title={absoluteTime(started)}>
                    {relativeTime(started, now)}
                  </time>
                  <span className="run-number">#{run.run_number}</span>
                </td>
                <td className="run-link-cell">
                  <a
                    className="run-link"
                    href={run.html_url}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    Open
                    <span className="visually-hidden">
                      {' '}
                      {run.workflow_name} in {run.repo_full_name}
                    </span>
                  </a>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
