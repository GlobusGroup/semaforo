import { signalLabel, type SignalKind } from '../lib/status'

interface StatusMarkProps {
  kind: SignalKind
  showLabel?: boolean
}

export function StatusMark({ kind, showLabel = true }: StatusMarkProps) {
  const label = signalLabel(kind)
  return (
    <span className={`status-mark status-mark--${kind}`} title={label}>
      <span className="status-mark__lamp" aria-hidden="true" />
      {showLabel ? (
        <span className="status-mark__label">{label}</span>
      ) : (
        <span className="visually-hidden">{label}</span>
      )}
    </span>
  )
}
