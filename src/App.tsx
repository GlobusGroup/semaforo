import { useEffect, useMemo, useState } from 'react'
import { Masthead } from './components/Masthead'
import { RunTable } from './components/RunTable'
import { StatusRail } from './components/StatusRail'
import { POLL_MS, useRuns } from './hooks/useRuns'
import { syncNotice } from './lib/sync'
import { countBySignal, signalOf, type SignalKind } from './lib/status'

export default function App() {
  const { data, error, detail, loading, refreshing, refresh } = useRuns()
  const [filter, setFilter] = useState<SignalKind | 'all'>('all')
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 15_000)
    return () => window.clearInterval(id)
  }, [])

  const counts = useMemo(() => countBySignal(data?.runs ?? []), [data])

  const filtered = useMemo(() => {
    const runs = data?.runs ?? []
    if (filter === 'all') return runs
    return runs.filter((run) => signalOf(run) === filter)
  }, [data, filter])

  if (loading && !data) {
    return (
      <div className="page">
        <Masthead
          repoCount={0}
          runCount={0}
          runningCount={0}
          fetchedAt={null}
          refreshing
          onRefresh={refresh}
        />
        <div className="panel panel--loading" role="status" aria-live="polite">
          <p className="panel__title">Pulling workflow runs…</p>
          <p className="panel__body">
            Scanning repos via <code>gh api</code>. First load can take a moment.
          </p>
          <div className="skeleton-lines" aria-hidden="true">
            <span />
            <span />
            <span />
            <span />
          </div>
        </div>
      </div>
    )
  }

  if (error && !data) {
    return (
      <div className="page">
        <Masthead
          repoCount={0}
          runCount={0}
          runningCount={0}
          fetchedAt={null}
          refreshing={refreshing}
          onRefresh={refresh}
        />
        <div className="panel panel--error" role="alert">
          <p className="panel__title">{error}</p>
          <p className="panel__body">
            {detail || 'Check that the GitHub CLI is installed and signed in.'}
          </p>
          <ol className="panel__steps">
            <li>
              Install CLI: <code>brew install gh</code>
            </li>
            <li>
              Authenticate: <code>gh auth login</code>
            </li>
            <li>Reload this page or hit Refresh.</li>
          </ol>
          <button type="button" className="btn" onClick={refresh}>
            Try again
          </button>
        </div>
      </div>
    )
  }

  const runs = data?.runs ?? []
  const emptyBoard = runs.length === 0
  const notice = data ? syncNotice(data.sync, now) : null

  return (
    <div className="page">
      <Masthead
        repoCount={data?.repo_count ?? 0}
        runCount={runs.length}
        runningCount={counts.running + counts.queued}
        fetchedAt={data?.fetched_at ?? null}
        refreshing={refreshing}
        onRefresh={refresh}
      />

      {error ? (
        <div className="banner" role="status">
          Last refresh failed: {detail || error}. Showing previous results.
        </div>
      ) : null}

      {notice ? (
        <div className="banner" role="status">
          {notice}
        </div>
      ) : null}

      {emptyBoard ? (
        <div className="empty-state empty-state--board" role="status">
          <p className="empty-state__title">No recent workflow runs</p>
          <p className="empty-state__body">
            Azioni scanned {data?.repo_count ?? 0} repos and found nothing in the latest five runs
            per repository. Trigger a workflow, then refresh.
          </p>
        </div>
      ) : (
        <div className="board">
          <StatusRail counts={counts} active={filter} onChange={setFilter} />
          <main className="board__main">
            <div className="board__toolbar">
              <h2 className="board__heading">
                {filter === 'all' ? 'Latest runs' : `${filter} runs`}
              </h2>
              <p className="board__sub">
                Sorted by <span className="mono">run_started_at</span>
              </p>
            </div>
            <RunTable runs={filtered} now={now} />
          </main>
        </div>
      )}

      <footer className="site-footer">
        <p>
          Azioni · local only · data via GitHub CLI · auto-refresh every {POLL_MS / 1000}s
        </p>
      </footer>
    </div>
  )
}
