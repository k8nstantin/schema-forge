// Table: one table complete, with a picker beside it. Above its columns, how it links: what refers to it on the
// left, what it refers to on the right, each line from the exact column that joins.

import { useEffect, useMemo, useState } from 'react'

import { definition } from '../api'
import { Sql } from '../components/Sql'
import { LinkDiagram, type Card, type Line, type Row } from '../diagram/LinkDiagram'
import { nested, typeLabel } from '../model'
import { partitioning, tableRef, useWorkbench } from '../state'

const MAX_SIDE = 14

export function TableView({ id }: { id?: string }) {
  const { name, model, ix, go, pointer, point } = useWorkbench()
  const [query, setQuery] = useState('')
  const [tab, setTab] = useState<'columns' | 'definition' | 'copies'>('columns')
  const [sql, setSql] = useState<string | null>(null)
  const first = (model.tables ?? []).find((t) => !ix.isCopy(t.id))
  const t = (id && ix.tables.get(id)) || first
  useEffect(() => {
    setSql(null)
    if (t && tab === 'definition') definition(name, t.id).then(setSql, (e) => setSql(`-- ${String(e.message ?? e)}`))
  }, [name, t, tab, model])
  const copies = t ? ix.copiesOf(t.id) : []
  useEffect(() => { if (tab === 'copies' && !copies.length) setTab('columns') }, [tab, copies.length])
  // The open table stays in sight in the picker.
  useEffect(() => { document.querySelector('.sf-pick.sf-on')?.scrollIntoView({ block: 'nearest' }) }, [t?.id])

  const picker = useMemo(() => {
    const q = query.trim().toLowerCase()
    return [...ix.namespaces.values()]
      .map((n) => ({ n, list: (model.tables ?? []).filter((x) => x.namespace === n.id && !ix.isCopy(x.id) && (!q || x.name.toLowerCase().includes(q))).sort((a, b) => a.name.localeCompare(b.name)) }))
      .filter((g) => g.list.length)
  }, [ix, model, query])

  if (!t) return <div className="sf-page sf-muted">This schema has no tables yet.</div>
  const fam = ix.familyOf(t.id)
  const outs = ix.out.get(t.id) ?? []
  const ins = ix.into.get(t.id) ?? []
  const sharedOut = ix.sharedOut.get(t.id) ?? []
  const sharedIn = ix.sharedIn.get(t.id) ?? []
  const colName = (c: string) => ix.columns.get(c)?.column.name ?? c

  // The diagram: one card per referring table (with its column), the table's joining columns, one card per target.
  const inByTable = [...new Map(ins.map((l) => [l.from, l])).values()].sort((a, b) => (ix.tables.get(a.from)?.name ?? '').localeCompare(ix.tables.get(b.from)?.name ?? ''))
  const outByTable = [...new Map(outs.map((l) => [l.to, l])).values()]
  const left: Card[] = inByTable.slice(0, MAX_SIDE).map((l) => ({ key: l.from, title: ix.tables.get(l.from)?.name ?? l.from, sub: `.${colName(l.column)}`, color: ix.familyOf(l.from)?.color, onClick: () => go('table', l.from) }))
  const right: Card[] = outByTable.slice(0, MAX_SIDE).map((l) => ({ key: l.to, title: ix.tables.get(l.to)?.name ?? l.to, sub: `by ${t.name}.${colName(l.column)}`, color: ix.familyOf(l.to)?.color, onClick: () => go('table', l.to) }))
  const joinCols = [...new Set(outs.map((l) => l.column))]
  const rows: Row[] = [
    ...(t.columns.length && !joinCols.includes(t.columns[0].id) ? [t.columns[0]] : []),
    ...joinCols.map((c) => ix.columns.get(c)!.column),
  ].map((c) => ({ key: c.id, name: c.name, note: typeLabel(c.type, model.target, ix.typeNames), joins: joinCols.includes(c.id), onClick: () => point({ kind: 'column', table: t.id, column: c.id }) }))
  const lines: Line[] = [
    ...left.map((c) => ({ side: 'left' as const, card: c.key })),
    ...outs.filter((l) => right.some((c) => c.key === l.to)).map((l) => ({ side: 'right' as const, card: l.to, row: l.column })),
  ]
  const nestedN = t.columns.filter((c) => nested(c.type).length).length
  const part = partitioning(ix, t)
  const writes = t.options?.iceberg?.properties?.['write.delete.mode']
  const pointedCol = pointer?.kind === 'column' && pointer.table === t.id ? pointer.column : null

  return (
    <div className="sf-split">
      <aside className="sf-picker">
        <input className="sf-input" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Find a table" aria-label="Find a table" />
        <div className="sf-picker-list">
          {picker.map(({ n, list }) => (
            <div key={n.id} className="sf-col">
              <div className="sf-picker-ns">
                <span className="sf-caption">namespace</span>
                <span className="sf-ns">{ix.path(n.id)} <span className="sf-muted sf-small">{list.length} tables</span></span>
              </div>
              {list.map((x) => (
                <button key={x.id} type="button" className={`sf-pick${x.id === t.id ? ' sf-on' : ''}`} onClick={() => go('table', x.id)}>
                  {x.name}{ix.copiesOf(x.id).length ? <span className="sf-muted"> ×{ix.copiesOf(x.id).length + 1}</span> : null}
                </button>
              ))}
            </div>
          ))}
        </div>
      </aside>
      <div className="sf-page sf-flex1">
        <nav className="sf-crumbs" aria-label="Where this table is">
          <button type="button" className="sf-link" onClick={() => go('categories')}>{name}</button>
          <span>›</span>
          <button type="button" className="sf-nspill" onClick={() => go('categories')}>{ix.path(t.namespace)}</button>
          <span>›</span>
          <button type="button" className="sf-link" onClick={() => fam && go('map', fam.key)}>{fam?.name}</button>
          <span>›</span>
          <span className="sf-strong">{t.name}</span>
        </nav>
        <div className="sf-titlerow">
          <button type="button" className="sf-title" onClick={() => point({ kind: 'table', table: t.id })} title="Point at it">{t.name}</button>
          <span className="sf-muted">
            {t.columns.length} columns{nestedN ? `, ${nestedN} nested` : ''}{part ? ` · partitioned by ${part}` : ''}{writes ? ` · ${writes}` : ''}
          </span>
        </div>
        {t.comment && <p className="sf-about">{t.comment}</p>}

        <section className="sf-col">
          <div className="sf-row-between">
            <span className="sf-caption">How it links · {ins.length} refer to it, it refers to {outs.length}</span>
            <span className="sf-muted sf-small">Click a table to open it; a row to point at that column.</span>
          </div>
          <LinkDiagram
            leftHead={`Refer to it · ${inByTable.length}${inByTable.length > MAX_SIDE ? ` (first ${MAX_SIDE})` : ''}`}
            rightHead={`It refers to · ${outByTable.length}`}
            left={left}
            right={right}
            lines={lines}
            center={{ caption: 'table', title: t.name, color: fam?.color ?? '#cc66ff', rows }}
            empty="No links found for this table."
          />
          {(sharedIn.length > 0 || sharedOut.length > 0) && (
            <div className="sf-shared">
              {sharedIn.length > 0 && `Shared key: ${sharedIn.length.toLocaleString()} tables refer to it (by ${[...new Set(sharedIn.map((l) => colName(l.column)))].slice(0, 3).join(', ')}). Too many to draw; they are listed in its sheet.`}
              {sharedOut.length > 0 && `Shared keys: ${[...new Set(sharedOut.map((l) => `${colName(l.column)} → ${ix.tables.get(l.to)?.name}`))].join(', ')}. Most tables carry them, so they are not drawn.`}
            </div>
          )}
        </section>

        <div className="sf-tabs" role="tablist">
          <button type="button" role="tab" aria-selected={tab === 'columns'} onClick={() => setTab('columns')}>Columns · {t.columns.length}</button>
          <button type="button" role="tab" aria-selected={tab === 'definition'} onClick={() => setTab('definition')}>Definition</button>
          {copies.length > 0 && <button type="button" role="tab" aria-selected={tab === 'copies'} onClick={() => setTab('copies')}>Copies · {copies.length}</button>}
        </div>
        {tab === 'columns' && (
          <div className="sf-coltable">
            <div className="sf-colrow sf-thead"><span>Column</span><span>Type</span><span>Required</span><span>Description</span></div>
            {t.columns.map((c) => (
              <button key={c.id} type="button" className={`sf-colrow${pointedCol === c.id ? ' sf-pointed' : ''}`} onClick={() => point({ kind: 'column', table: t.id, column: c.id })}>
                <span className="sf-mono sf-strong">{c.name}</span>
                <span className={`sf-mono ${nested(c.type).length ? 'sf-nested' : 'sf-type'}`}>{typeLabel(c.type, model.target, ix.typeNames)}{nested(c.type).length ? ` · ${nested(c.type).length} fields` : ''}</span>
                <span className="sf-muted">{c.nullable ? 'may be empty' : 'required'}</span>
                <span className="sf-muted">{c.comment}</span>
              </button>
            ))}
          </div>
        )}
        {tab === 'definition' && <div className="sf-sqlbox">{sql === null ? <span className="sf-muted">Writing it…</span> : <Sql text={sql} target={model.target} />}</div>}
        {tab === 'copies' && (
          <div className="sf-coltable">
            {ix.placed.get(t.id)?.stack && <div className="sf-colrow sf-thead"><span>{ix.placed.get(t.id)!.stack!.label}</span></div>}
            {copies.sort((a, b) => a.name.localeCompare(b.name)).map((c) => (
              <div key={c.id} className="sf-copyrow sf-mono">{c.name} <span className="sf-muted">{tableRef(ix, c.id)}</span></div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
