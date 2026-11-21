// Tables, as the "Perspective · Tables" board draws it: find a table or a column, pick a namespace, sort by any
// column; every table (and view) under its namespace, with its family, columns, nested columns, partitioning and
// links. A row opens the table.

import { useMemo, useState } from 'react'

import { nested } from '../model'
import { partitioning, useWorkbench } from '../state'

type Key = 'name' | 'family' | 'columns' | 'nested' | 'partition' | 'links'
const HEADS: [Key, string][] = [['name', 'Table'], ['family', 'Family'], ['columns', 'Columns'], ['nested', 'Nested'], ['partition', 'Partitioned by'], ['links', 'Links']]

export function Tables() {
  const { model, ix, go } = useWorkbench()
  const [query, setQuery] = useState('')
  const [ns, setNs] = useState('')
  const [sort, setSort] = useState<{ key: Key; dir: number }>({ key: 'name', dir: 1 })
  const q = query.trim().toLowerCase()
  const rows = useMemo(() => {
    return (model.tables ?? [])
      .filter((t) => !ix.isCopy(t.id))
      .filter((t) => !ns || t.namespace === ns)
      .filter((t) => !q || t.name.toLowerCase().includes(q) || t.columns.some((c) => c.name.toLowerCase().includes(q)))
      .map((t) => {
        const fam = ix.familyOf(t.id)
        const out = ix.out.get(t.id)?.length ?? 0
        const into = ix.into.get(t.id)?.length ?? 0
        return {
          t, fam, out, into,
          cols: t.columns.length,
          nestedN: t.columns.filter((c) => nested(c.type).length).length,
          partition: partitioning(ix, t),
          copies: ix.copiesOf(t.id).length,
        }
      })
      .sort((a, b) => {
        const v = (r: typeof a): string | number =>
          sort.key === 'name' ? r.t.name : sort.key === 'family' ? r.fam?.name ?? '' : sort.key === 'columns' ? r.cols : sort.key === 'nested' ? r.nestedN : sort.key === 'partition' ? r.partition : r.out + r.into
        const x = v(a), y = v(b)
        return (typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y))) * sort.dir || a.t.name.localeCompare(b.t.name)
      })
  }, [model, ix, q, ns, sort])
  const namespaces = [...ix.namespaces.values()].filter((n) => (model.tables ?? []).some((t) => t.namespace === n.id) || (model.views ?? []).some((v) => v.namespace === n.id))
  const total = (model.tables ?? []).filter((t) => !ix.isCopy(t.id)).length
  const inNs = (id: string) => (model.tables ?? []).filter((t) => t.namespace === id && !ix.isCopy(t.id)).length
  const chips = [{ id: '', label: `All · ${total}` }, ...namespaces.map((n) => ({ id: n.id, label: `${ix.path(n.id)} · ${inNs(n.id)}` }))]

  return (
    <main className="d-persp-main">
      <div className="d-row" style={{ justifyContent: 'space-between' }}>
        <label className="d-col d-gap-4" style={{ flex: '1 1 320px', maxWidth: 460 }}>
          <span className="d-kicker" style={{ fontSize: 12, letterSpacing: '0.05em' }}>Find a table or a column</span>
          <input className="d-find" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="orders, created_at…" />
        </label>
        <div className="d-row" style={{ gap: 6 }}>
          {chips.map((c) => (
            <button key={c.id} type="button" className={`d-nschip${ns === c.id ? ' d-nschip-on' : ''}`} onClick={() => setNs(c.id)}>{c.label}</button>
          ))}
        </div>
      </div>

      <div className="d-tbl">
        <div className="d-tbl-row d-tbl-head">
          {HEADS.map(([k, label], i) => (
            <button key={k} type="button" className={`d-sort${sort.key === k ? ' d-sort-on' : ''}`} style={{ textAlign: i >= 2 && i !== 4 ? 'right' : 'left' }}
              onClick={() => setSort({ key: k, dir: sort.key === k ? -sort.dir : 1 })}>
              {label}{sort.key === k ? (sort.dir > 0 ? ' ↑' : ' ↓') : ''}
            </button>
          ))}
        </div>
        {namespaces.filter((n) => !ns || n.id === ns).map((n) => {
          const mine = rows.filter((r) => r.t.namespace === n.id)
          const views = (model.views ?? []).filter((v) => v.namespace === n.id && (!q || v.name.toLowerCase().includes(q)))
          if (!mine.length && !views.length) return null
          return (
            <div key={n.id}>
              <div className="d-nshead">
                <span className="d-kicker">namespace</span>
                <span className="d-nsname">{ix.path(n.id)}</span>
                <span className="d-xsmall d-soft">{mine.length} tables{views.length ? ` · ${views.length} views` : ''}</span>
              </div>
              {mine.map((r) => (
                <button key={r.t.id} type="button" className="d-tbl-row d-tbl-line" onClick={() => go('table', r.t.id)}>
                  <span className="d-col" style={{ minWidth: 0 }}>
                    <span className="d-tname">{r.t.name}{r.copies ? <span className="d-soft"> ×{r.copies + 1}</span> : null}</span>
                    {r.t.comment && <span className="d-tnote">{r.t.comment}</span>}
                  </span>
                  <span className="d-fam"><span className="d-famdot" style={{ background: r.fam?.color }} />{r.fam?.name}</span>
                  <span className="d-cnum">{r.cols}</span>
                  <span className="d-cnum d-nested">{r.nestedN || ''}</span>
                  <span className="d-part">{r.partition}</span>
                  <span className="d-links">{r.out} out · {r.into} in</span>
                </button>
              ))}
              {views.map((v) => (
                <button key={v.id} type="button" className="d-tbl-row d-tbl-line" onClick={() => go('table', v.id)}>
                  <span className="d-col" style={{ minWidth: 0 }}>
                    <span className="d-tname">{v.name}</span>
                    {v.comment && <span className="d-tnote">{v.comment}</span>}
                  </span>
                  <span className="d-fam"><span className="d-famdot d-famdot-view" />{v.options?.postgres?.materialized ? 'materialized view' : 'view'}</span>
                  <span className="d-cnum">{v.columns?.length || ''}</span>
                  <span className="d-cnum" />
                  <span className="d-part" />
                  <span className="d-links">reads {v.reads?.length ?? 0}</span>
                </button>
              ))}
            </div>
          )
        })}
      </div>
      <span className="d-xsmall d-soft">{rows.length === total && !q ? `${total} tables. Click a row to open it.` : `${rows.length} of ${total} tables`}</span>
    </main>
  )
}
