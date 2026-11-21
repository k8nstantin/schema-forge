// The bar over every perspective of a schema, as the "Perspective · …" boards draw it: the name and the schema, its
// type, the perspectives, and what the one you are on counts.

import { useEffect, useRef, useState } from 'react'

import type { Perspective } from '../state'
import type { SchemaInfo } from '../model'
import { targetLabel } from './parts'

const PERSPECTIVES: { value: Perspective; label: string }[] = [
  { value: 'table', label: 'Tables' },
  { value: 'categories', label: 'Categories' },
  { value: 'map', label: 'Map' },
  { value: 'rules', label: 'Rules' },
]

export function SchemaBar({ name, info, all, on, go, count, switchTo }: {
  name: string
  info: Pick<SchemaInfo, 'target' | 'iceberg_format'> | null
  /// Every schema of the workspace, to switch to.
  all: SchemaInfo[]
  on: Perspective
  go: (p: Perspective) => void
  count?: string
  /// Opens another schema on the same perspective.
  switchTo: (schema: string) => void
}) {
  const [open, setOpen] = useState(false)
  const box = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const away = (e: MouseEvent) => { if (!box.current?.contains(e.target as Node)) setOpen(false) }
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', away)
    document.addEventListener('keydown', esc)
    return () => { document.removeEventListener('mousedown', away); document.removeEventListener('keydown', esc) }
  }, [open])
  return (
    <header className="d-bar d-bar-tight">
      <div className="d-row" style={{ gap: 14 }}>
        <a href="#/" className="d-brand-text">Schema Forge</a>
        <span className="d-slash">/</span>
        <div className="d-switch-box" ref={box}>
          <button type="button" className="d-switcher" aria-haspopup="listbox" aria-expanded={open} onClick={() => setOpen(!open)} title="Switch to another schema">
            <span className="d-kicker">schema</span>
            <span className="d-schema-name">{name}</span>
            <span aria-hidden="true" className="d-soft" style={{ fontSize: 14 }}>▾</span>
          </button>
          {open && (
            <div className="d-menu" role="listbox" aria-label="Schemas">
              {all.map((s) => (
                <button key={s.name} type="button" role="option" aria-selected={s.name === name}
                  className={`d-menu-item${s.name === name ? ' d-menu-on' : ''}`}
                  onClick={() => { setOpen(false); if (s.name !== name) switchTo(s.name) }}>
                  <span className="d-mono">{s.name}</span>
                  <span className="d-tag">{targetLabel(s)}</span>
                </button>
              ))}
              <a className="d-menu-item d-menu-foot" href="#/_new">New schema…</a>
              <a className="d-menu-item d-menu-foot" href="#/_open">Open a file or folder…</a>
            </div>
          )}
        </div>
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
