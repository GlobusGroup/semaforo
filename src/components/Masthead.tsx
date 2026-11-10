import { formatFetchedAt } from '../lib/format'

interface MastheadProps {
  repoCount: number
  runCount: number
  runningCount: number
  fetchedAt: string | null
  refreshing: boolean
  onRefresh: () => void
}

export function Masthead({
  repoCount,
  runCount,
  runningCount,
  fetchedAt,
  refreshing,
  onRefresh,
}: MastheadProps) {
  return (
    <header className="masthead">
      <div className="masthead__brand">
        <p className="masthead__eyebrow">Local · GitHub CLI</p>
        <h1 className="masthead__title">Azioni</h1>
        <p className="masthead__lede">
          Workflow runs across your repos, newest start first.
        </p>
      </div>

      <div className="masthead__meta">
        <dl className="masthead__stats">
          <div>
            <dt>Repos</dt>
            <dd>{repoCount}</dd>
          </div>
          <div>
            <dt>Runs shown</dt>
            <dd>{runCount}</dd>
          </div>
          <div>
            <dt>Live</dt>
            <dd className={runningCount > 0 ? 'is-live' : undefined}>{runningCount}</dd>
          </div>
        </dl>

        <div className="masthead__actions">
          <p className="masthead__clock" aria-live="polite">
            {fetchedAt ? (
              <>
                Updated <time dateTime={fetchedAt}>{formatFetchedAt(fetchedAt)}</time>
              </>
            ) : (
              'Waiting for first pull…'
            )}
          </p>
          <button
            type="button"
            className="btn"
            onClick={onRefresh}
            disabled={refreshing}
            aria-busy={refreshing}
          >
            {refreshing ? 'Refreshing…' : 'Refresh'}
          </button>
        </div>
      </div>
    </header>
  )
}
