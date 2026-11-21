// Table, as the "Perspective · Table" board draws it: every table on the left by namespace; the open one with where
// it is, what it holds and how it links (what refers to it, what it refers to, each line from the joining column);
// then its columns or its definition. Rules and Edit sit beside them as tabs of the same kind.

import { useEffect, useMemo, useState } from 'react'

import { definition } from '../api'
import { Sql } from '../components/Sql'
import { LinkDiagram, type Card, type Line, type Row } from '../diagram/LinkDiagram'
import { nested, typeLabel, type Table as T } from '../model'
import { TableEdit } from '../perspectives/TableEdit'
import { TableView } from '../perspectives/TableView'
import { Findings } from '../rules/parts'
import { scopeTitle } from '../rules/scope'
import { partitioning, tableRef, useWorkbench } from '../state'

const MAX_SIDE = 14
type Tab = 'columns' | 'definition' | 'rules' | 'copies' | 'edit'

export function Table({ id }: { id?: string }) {
  const { model } = useWorkbench()
  // A view keeps its own screen for now: fields, full SQL and what it reads.
  if (id && (model.views ?? []).some((v) => v.id === id)) return <TableView id={id} />
  return <TableOf id={id} />
}

/// Every table and view by namespace, to open one; the open one stays in sight.
function Picker({ current }: { current: string }) {
  const { model, ix, go } = useWorkbench()
  const [query, setQuery] = useState('')
  // Only the list scrolls to the open table; the page stays where it is.
  useEffect(() => {
    const list = document.querySelector<HTMLElement>('.d-picker-list')
    const on = document.querySelector<HTMLElement>('.d-pick-on')
    if (list && on && (on.offsetTop < list.scrollTop || on.offsetTop > list.scrollTop + list.clientHeight - 40)) {
      list.scrollTop = on.offsetTop - list.clientHeight / 3
    }
  }, [current])
  const groups = useMemo(() => {
    const q = query.trim().toLowerCase()
    const hit = (n: string) => !q || n.toLowerCase().includes(q)
    return [...ix.namespaces.values()]
      .map((n) => ({
        n,
        tables: (model.tables ?? []).filter((x) => x.namespace === n.id && !ix.isCopy(x.id) && hit(x.name)).sort((a, b) => a.name.localeCompare(b.name)),
        views: (model.views ?? []).filter((x) => x.namespace === n.id && hit(x.name)).sort((a, b) => a.name.localeCompare(b.name)),
      }))
      .filter((g) => g.tables.length || g.views.length)
  }, [ix, model, query])
  return (
    <aside className="d-picker">
      <input className="d-find" style={{ fontSize: 14, padding: '9px 12px' }} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Find a table" aria-label="Find a table" />
      <div className="d-picker-list">
        {groups.map(({ n, tables, views }) => (
          <div key={n.id} className="d-col" style={{ gap: 1 }}>
            <span className="d-picker-ns">
              <span className="d-kicker">namespace</span>
              <span className="d-picker-nsname">{ix.path(n.id)} <span className="d-soft" style={{ fontFamily: 'var(--d-body)', fontWeight: 400, fontSize: 12 }}>{tables.length} tables{views.length ? `, ${views.length} views` : ''}</span></span>
            </span>
            {tables.map((x) => (
              <button key={x.id} type="button" className={`d-pick-item${x.id === current ? ' d-pick-on' : ''}`} onClick={() => go('table', x.id)}>{x.name}</button>
            ))}
            {views.map((x) => (
              <button key={x.id} type="button" className="d-pick-item" onClick={() => go('table', x.id)}>{x.name} <span className="d-soft">view</span></button>
            ))}
          </div>
        ))}
      </div>
    </aside>
  )
}

function TableOf({ id }: { id?: string }) {
  const { name, model, ix, go, pointer, point, rules, catalog } = useWorkbench()
  const [tab, setTab] = useState<Tab>('columns')
  const [sql, setSql] = useState<string | null>(null)
  const first = (model.tables ?? []).find((t) => !ix.isCopy(t.id))
  const t: T | undefined = (id && ix.tables.get(id)) || first
  useEffect(() => {
    setSql(null)
    if (t && tab === 'definition') definition(name, t.id).then(setSql, (e) => setSql(`-- ${String(e.message ?? e)}`))
  }, [name, t, tab, model])
  const copies = t ? ix.copiesOf(t.id) : []
  useEffect(() => { if (tab === 'copies' && !copies.length) setTab('columns') }, [tab, copies.length])

  if (!t) return <main className="d-persp-main d-soft">This schema has no tables yet.</main>
  const fam = ix.familyOf(t.id)
  const outs = ix.out.get(t.id) ?? []
  const ins = ix.into.get(t.id) ?? []
  const colName = (c: string) => ix.columns.get(c)?.column.name ?? c

  const inByTable = [...new Map(ins.map((l) => [l.from, l])).values()].sort((a, b) => (ix.tables.get(a.from)?.name ?? '').localeCompare(ix.tables.get(b.from)?.name ?? ''))
  const outByTable = [...new Map(outs.map((l) => [l.to, l])).values()]
  const readers = (model.views ?? []).filter((v) => v.reads?.includes(t.id))
  const left: Card[] = [
    ...inByTable.slice(0, MAX_SIDE).map((l) => ({ key: l.from, title: ix.tables.get(l.from)?.name ?? l.from, sub: `.${colName(l.column)}`, color: ix.familyOf(l.from)?.color, onClick: () => go('table', l.from) })),
    ...readers.slice(0, MAX_SIDE).map((v) => ({ key: v.id, title: v.name, meta: 'view', sub: 'reads it', color: '#7fb2ff', onClick: () => go('table', v.id) })),
  ]
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
  const eff = rules.report.tables[t.id]
  const findings = rules.report.findings.filter((f) => f.table === t.id)
  const ruleTitle = (r: string) => (r === '*' ? 'All rules' : catalog.rules.find((x) => x.id === r)?.title ?? r)
  const tabs: [Tab, string][] = [
    ['columns', `Columns · ${t.columns.length}`],
    ['definition', 'Definition'],
    ['rules', `Rules · ${eff?.applied.length ?? 0}${findings.length ? ` · ${findings.length} ${findings.length === 1 ? 'break' : 'breaks'}` : ''}`],
    ...(copies.length ? [['copies', `Copies · ${copies.length}`] as [Tab, string]] : []),
    ['edit', 'Edit'],
  ]
  const facts = [
    `${t.columns.length} columns${nestedN ? `, ${nestedN} nested` : ''}`,
    part ? `partitioned by ${part}` : model.target === 'iceberg' ? 'partitioned by nothing' : '',
    writes ?? '',
  ].filter(Boolean).join(' · ')

  return (
    <div className="d-split">
      <Picker current={t.id} />
      <main className="d-split-main">
        <div className="d-col d-gap-6">
          <nav aria-label="Where this table is" className="d-crumbs">
            <button type="button" className="d-crumb" onClick={() => go('categories')}>{name}</button><span className="d-slash">›</span>
            <button type="button" className="d-crumb-ns" onClick={() => go('categories')}>{ix.path(t.namespace)}</button><span className="d-slash">›</span>
            <button type="button" className="d-crumb" onClick={() => fam && go('map', fam.key)}>{fam?.name}</button><span className="d-slash">›</span>
            <span style={{ color: 'var(--d-bright)' }}>{t.name}</span>
          </nav>
          <div className="d-row" style={{ alignItems: 'baseline', gap: 14 }}>
            <button type="button" className="d-ttitle" onClick={() => point({ kind: 'table', table: t.id })} title="Point at it">{t.name}</button>
            <span className="d-soft">{facts}</span>
          </div>
          {t.comment && <p className="d-about">{t.comment}</p>}
        </div>

        <section className="d-col d-gap-10">
          <div className="d-row" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
            <span className="d-caps d-caps-sm">How it links · {ins.length} refer to it, it refers to {outs.length}</span>
            <span className="d-xsmall d-soft">{model.target === 'iceberg' ? 'Inferred from the _id columns; Iceberg declares none. ' : ''}Click a table to open it.</span>
          </div>
          <LinkDiagram
            leftHead={`Refer to it · ${inByTable.length}${inByTable.length > MAX_SIDE ? ` (first ${MAX_SIDE})` : ''}${readers.length ? ` · read by ${readers.length} views` : ''}`}
            rightHead={`It refers to · ${outByTable.length}`}
            left={left}
            right={right}
            lines={lines}
            center={{ caption: 'table', title: t.name, color: '#cc66ff', rows }}
            empty="No links found for this table."
          />
        </section>

        <div className="d-tabs" role="tablist">
          {tabs.map(([k, label]) => (
            <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? 'd-tab-on' : undefined} onClick={() => setTab(k)}>{label}</button>
          ))}
        </div>

        {tab === 'columns' && (
          <>
            <div className="d-tbl">
              <div className="d-crow d-tbl-head"><span>Column</span><span>Type</span><span>Required</span><span>Description</span></div>
              {t.columns.map((c) => (
                <button key={c.id} type="button" className={`d-crow d-crow-line${pointedCol === c.id ? ' d-crow-on' : ''}`} onClick={() => point({ kind: 'column', table: t.id, column: c.id })}>
                  <span className="d-mono" style={{ fontSize: 14, color: 'var(--d-bright)', overflowWrap: 'anywhere' }}>{c.name}</span>
                  <span className="d-mono" style={{ fontSize: 13, color: nested(c.type).length ? 'var(--d-blue)' : 'var(--d-lilac)', overflowWrap: 'anywhere' }}>{typeLabel(c.type, model.target, ix.typeNames)}</span>
                  <span className="d-xsmall d-soft">{c.nullable ? 'may be empty' : 'required'}</span>
                  <span className="d-small d-soft">{c.comment}</span>
                </button>
              ))}
            </div>
            <span className="d-xsmall d-soft">Click a column to point at it; Copy puts its reference on the clipboard for the agent.</span>
          </>
        )}
        {tab === 'definition' && (
          <div className="d-sql">{sql === null ? <span className="d-soft">Writing it…</span> : <Sql text={sql} target={model.target} />}</div>
        )}
        {tab === 'rules' && (
          <section className="d-col d-gap-10">
            {!eff?.applied.length && !eff?.excepted?.length ? (
              <span className="d-soft d-small">No rules reach this table. <button type="button" className="d-crumb" onClick={() => go('rules', `level:table:${t.id}`)}>Link one</button></span>
            ) : (
              <>
                <div className="d-row d-gap-8">
                  {eff.applied.map((a) => (
                    <button key={a.rule} type="button" className="d-chip d-chip-btn" onClick={() => go('rules', `rule:${a.rule}`)}>
                      {ruleTitle(a.rule)} <span className="d-soft">· {a.from.level === 'global' ? 'every schema' : scopeTitle(ix, name, a.from)}</span>
                    </button>
                  ))}
                  {(eff.excepted ?? []).map((e) => (
                    <span key={e.rule} className="d-chip" style={{ textDecoration: 'line-through' }} title={e.reason}>{ruleTitle(e.rule)} · off: {e.reason}</span>
                  ))}
                </div>
                <Findings findings={findings} limit={20} />
              </>
            )}
          </section>
        )}
        {tab === 'copies' && (
          <div className="d-tbl">
            {copies.sort((a, b) => a.name.localeCompare(b.name)).map((c) => (
              <div key={c.id} className="d-crow d-crow-line"><span className="d-mono">{c.name}</span><span className="d-ref">{tableRef(ix, c.id)}</span></div>
            ))}
          </div>
        )}
        {tab === 'edit' && <TableEdit t={t} />}
      </main>
    </div>
  )
}
