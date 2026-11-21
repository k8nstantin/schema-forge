// Pieces every screen shares, as the boards draw them: the mark and name, and how a schema, a person and a time read.

import type { SchemaInfo } from '../model'

/// The four-square mark and the name; it leads home.
export function Brand({ size = 28 }: { size?: number }) {
  return (
    <a className="d-brand" href="#/">
      <svg width={size} height={size} viewBox="0 0 28 28" aria-hidden="true">
        <rect x="2" y="2" width="11" height="11" rx="3" fill="#9500bf" />
        <rect x="15" y="2" width="11" height="11" rx="3" fill="#cc66ff" />
        <rect x="2" y="15" width="11" height="11" rx="3" fill="#cc66ff" />
        <rect x="15" y="15" width="11" height="11" rx="3" fill="#630080" />
      </svg>
      <span className="d-brand-name" style={size < 28 ? { fontSize: 18 } : undefined}>Schema Forge</span>
    </a>
  )
}

const TARGETS = { postgres: 'PostgreSQL', mysql: 'MySQL', iceberg: 'Iceberg' } as const

/// `PostgreSQL`, `Iceberg v2`.
export function targetLabel(info: Pick<SchemaInfo, 'target' | 'iceberg_format'>): string {
  const t = TARGETS[info.target]
  return info.target === 'iceberg' && info.iceberg_format ? `${t} v${info.iceberg_format}` : t
}

/// Who made a change, in words.
export function who(by: string): string {
  if (by === 'agent') return 'the agent'
  if (by === 'you') return 'you'
  return by
}

/// `just now`, `4 min ago`, `2 h ago`, `yesterday`, `3 days ago`; nothing known, `a while ago`.
export function ago(at?: number): string {
  if (!at) return 'a while ago'
  const s = Math.max(0, (Date.now() - at) / 1000)
  if (s < 45) return 'just now'
  if (s < 3600) return `${Math.round(s / 60)} min ago`
  if (s < 86400) return `${Math.round(s / 3600)} h ago`
  const d = Math.round(s / 86400)
  return d === 1 ? 'yesterday' : `${d} days ago`
}
