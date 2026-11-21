// The bar over every perspective of a schema, as the "Perspective · …" boards draw it: the name and the schema, its
// type, the five perspectives, and what the one you are on counts.

import type { Perspective } from '../state'
import type { SchemaInfo } from '../model'
import { targetLabel } from './parts'

const PERSPECTIVES: { value: Perspective; label: string }[] = [
  { value: 'tables', label: 'Tables' },
  { value: 'categories', label: 'Categories' },
  { value: 'table', label: 'Table' },
  { value: 'map', label: 'Map' },
  { value: 'rules', label: 'Rules' },
]

export function SchemaBar({ name, info, on, go, count }: {
  name: string
  info: Pick<SchemaInfo, 'target' | 'iceberg_format'> | null
  on: Perspective
  go: (p: Perspective) => void
  count?: string
}) {
  return (
    <header className="d-bar d-bar-tight">
      <div className="d-row" style={{ gap: 14 }}>
        <a href="#/" className="d-brand-text">Schema Forge</a>
        <span className="d-slash">/</span>
        <span className="d-row d-gap-8" style={{ alignItems: 'baseline' }}>
          <span className="d-kicker">schema</span>
          <span className="d-schema-name">{name}</span>
        </span>
        {info && <span className="d-tag d-tag-lg">{targetLabel(info)}</span>}
      </div>
      <nav aria-label="Perspectives" className="d-persp">
        {PERSPECTIVES.map((p, i) => (
          <button key={p.value} type="button" aria-current={on === p.value ? 'page' : undefined} title={`${p.label} (${i + 1})`}
            className={on === p.value ? 'd-persp-on' : undefined} onClick={() => go(p.value)}>
            {p.label}
          </button>
        ))}
      </nav>
      <span className="d-small d-soft">{count ?? ''}</span>
    </header>
  )
}
