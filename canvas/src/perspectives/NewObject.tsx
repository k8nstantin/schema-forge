// Making a table or a view by hand, in a namespace there is or a new one; and a new schema from Home.

import { useState } from 'react'

import { newSchema } from '../api'
import { useWorkbench } from '../state'

/// The id the model gives a new object: its kind's letter and its name, lowercased, other characters as `_`; and,
/// as the server does, numbered (`_2`, `_3`) when that id is taken anywhere in the schema.
function idOf(model: import('../model').Schema, prefix: string, name: string): string {
  const base = `${prefix}_${name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '')}`
  const taken = new Set<string>([
    ...(model.namespaces ?? []).map((n) => n.id),
    ...(model.tables ?? []).flatMap((t) => [t.id, ...t.columns.map((c) => c.id), ...(t.indexes ?? []).map((i) => i.id)]),
    ...(model.views ?? []).map((v) => v.id),
    ...(model.relationships ?? []).map((r) => r.id),
  ])
  if (!taken.has(base)) return base
  for (let n = 2; ; n++) if (!taken.has(`${base}_${n}`)) return `${base}_${n}`
}

export function NewObject() {
  const { model, ix, edit, go } = useWorkbench()
  const [open, setOpen] = useState(false)
  const [kind, setKind] = useState<'table' | 'view'>('table')
  const namespaces = [...ix.namespaces.values()]
  // With no namespace yet, a new one is what there is to choose.
  const [ns, setNs] = useState(namespaces[0]?.id ?? '+')
  const [newNs, setNewNs] = useState('')
  const [name, setName] = useState('')
  const [about, setAbout] = useState('')
  const [sql, setSql] = useState('SELECT …')
  if (!open) return <button type="button" className="sf-button" onClick={() => setOpen(true)}>New</button>
  const iceberg = model.target === 'iceberg'
  const make = () => {
    const where = ns === '+' ? newNs.trim() : ns
    const ops: unknown[] = ns === '+' ? [{ op: 'add_namespace', name: where }] : []
    if (kind === 'table') {
      ops.push({ op: 'add_table', namespace: where, name: name.trim(), comment: about.trim() || undefined, columns: [{ name: 'id', type: iceberg ? 'string' : 'bigint', nullable: false }], primary_key: ['id'] })
    } else {
      ops.push({ op: 'add_view', namespace: where, name: name.trim(), comment: about.trim() || undefined, definition: sql })
    }
    const id = idOf(model, kind === 'table' ? 't' : 'v', name.trim())
    edit(ops).then((ok) => {
      if (!ok) return
      setOpen(false)
      setName('')
      setAbout('')
      go('table', id)
    })
  }
  return (
    <section className="sf-edit-section">
      <span className="sf-editbar">
        <span className="sf-enforce" role="group" aria-label="What to make">
          <button type="button" className={kind === 'table' ? 'sf-on-plain' : ''} onClick={() => setKind('table')}>Table</button>
          <button type="button" className={kind === 'view' ? 'sf-on-plain' : ''} onClick={() => setKind('view')}>View</button>
        </span>
        <span className="sf-muted">in</span>
        <select className="sf-edit-input" value={ns} onChange={(e) => setNs(e.target.value)} aria-label="Namespace">
          {namespaces.map((n) => <option key={n.id} value={n.id}>{ix.path(n.id)}</option>)}
          <option value="+">a new namespace…</option>
        </select>
        {ns === '+' && <input className="sf-edit-input" value={newNs} onChange={(e) => setNewNs(e.target.value)} placeholder="namespace" aria-label="New namespace" />}
        <input className="sf-edit-input sf-mono" value={name} onChange={(e) => setName(e.target.value)} placeholder={kind === 'table' ? 'table name' : 'view name'} aria-label="Name" />
        <input className="sf-edit-input sf-flex1" value={about} onChange={(e) => setAbout(e.target.value)} placeholder="what one row of it is" aria-label="Description" />
        <button type="button" className="sf-button" disabled={!name.trim() || (ns === '+' && !newNs.trim()) || !ns} onClick={make}>Make it</button>
        <button type="button" className="sf-chip" onClick={() => setOpen(false)}>Cancel</button>
      </span>
      {kind === 'table' && <span className="sf-muted sf-small">It starts with a required `id` as its key; add and change columns in the Table perspective.</span>}
      {kind === 'view' && <textarea className="sf-sql-edit" value={sql} onChange={(e) => setSql(e.target.value)} spellCheck={false} aria-label="The view's query" />}
    </section>
  )
}

export function NewSchema({ opened }: { opened: (name: string) => void }) {
  const [name, setName] = useState('')
  const [target, setTarget] = useState('iceberg')
  const [error, setError] = useState<string | null>(null)
  return (
    <section className="sf-edit-section">
      <span className="sf-caption">A new schema: no rules until you link them</span>
      <span className="sf-editbar">
        <input className="sf-edit-input sf-mono" value={name} onChange={(e) => setName(e.target.value)} placeholder="name: lowercase, digits, - and _" aria-label="Schema name" />
        <select className="sf-edit-input" value={target} onChange={(e) => setTarget(e.target.value)} aria-label="Type">
          <option value="iceberg">Iceberg</option>
          <option value="postgres">PostgreSQL</option>
          <option value="mysql">MySQL</option>
        </select>
        <button type="button" className="sf-button" disabled={!name.trim()}
          onClick={() => newSchema(name.trim(), target).then(() => opened(name.trim()), (e) => setError(String(e.message ?? e)))}>Make it</button>
      </span>
      {error && <span className="sf-error">{error}</span>}
    </section>
  )
}
