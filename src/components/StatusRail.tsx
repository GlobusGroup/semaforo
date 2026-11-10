import { signalLabel, type SignalKind } from '../lib/status'

const ORDER: SignalKind[] = ['running', 'queued', 'failure', 'success', 'cancelled', 'neutral']

interface StatusRailProps {
  counts: Record<SignalKind, number>
  active: SignalKind | 'all'
  onChange: (value: SignalKind | 'all') => void
}

export function StatusRail({ counts, active, onChange }: StatusRailProps) {
  const total = ORDER.reduce((sum, key) => sum + counts[key], 0)

  return (
    <aside className="status-rail" aria-label="Filter by status">
      <p className="status-rail__heading">Signal</p>
      <ul className="status-rail__list">
        <li>
          <button
            type="button"
            className={active === 'all' ? 'is-active' : undefined}
            onClick={() => onChange('all')}
            aria-pressed={active === 'all'}
          >
            <span className="status-rail__dot status-rail__dot--all" aria-hidden="true" />
            <span>All</span>
            <span className="status-rail__count">{total}</span>
          </button>
        </li>
        {ORDER.map((kind) => (
          <li key={kind}>
            <button
              type="button"
              className={`status-rail__btn status-rail__btn--${kind}${active === kind ? ' is-active' : ''}`}
              onClick={() => onChange(kind)}
              aria-pressed={active === kind}
              disabled={counts[kind] === 0}
            >
              <span className="status-rail__dot" aria-hidden="true" />
              <span>{signalLabel(kind)}</span>
              <span className="status-rail__count">{counts[kind]}</span>
            </button>
          </li>
        ))}
      </ul>
    </aside>
  )
}
