// Tables: every table of the schema as a row, under its namespace, to find, sort and open.

import { useMemo, useState } from 'react'

import { nested } from '../model'
import { partitioning, useWorkbench } from '../state'
import { NewObject } from './NewObject'

type Key = 'name' | 'family' | 'columns' | 'nested' | 'partition' | 'links'
const HEADS: [Key, string][] = [['name', 'Table'], ['family', 'Family'], ['columns', 'Columns'], ['nested', 'Nested'], ['partition', 'Partitioned by'], ['links', 'Links']]

export function Tables() {
  const { model, ix, go } = useWorkbench()
  const [query, setQuery] = useState('')
  const [ns, setNs] = useState('')
  const [sort, setSort] = useState<{ key: Key; dir: number }>({ key: 'name', dir: 1 })
  const rows = useMemo(() => {
    const q = query.trim().toLowerCase()
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
  }, [model, ix, query, ns, sort])
  const namespaces = [...ix.namespaces.values()].filter((n) => (model.tables ?? []).some((t) => t.namespace === n.id))
  const total = (model.tables ?? []).filter((t) => !ix.isCopy(t.id)).length
  return (
    <div className="sf-page">
      <NewObject />
      <div className="sf-toolbar">
        <label className="sf-field">
          <span className="sf-caption">Find a table or a column</span>
          <input className="sf-input" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="orders, created_at…" />
        </label>
        <div className="sf-chips">
          {[{ id: '', name: `All · ${total}` }, ...namespaces.map((n) => ({ id: n.id, name: `${ix.path(n.id)} · ${(model.tables ?? []).filter((t) => t.namespace === n.id && !ix.isCopy(t.id)).length}` }))].map((n) => (
            <button key={n.id} type="button" className={`sf-chip${ns === n.id ? ' sf-on' : ''}`} onClick={() => setNs(n.id)}>{n.name}</button>
          ))}
        </div>
      </div>
      <div className="sf-grid-table">
        <div className="sf-trow sf-thead">
          {HEADS.map(([k, label]) => (
            <button key={k} type="button" className={`sf-sort${sort.key === k ? ' sf-on' : ''}`} onClick={() => setSort({ key: k, dir: sort.key === k ? -sort.dir : 1 })}>
              {label}{sort.key === k ? (sort.dir > 0 ? ' ↑' : ' ↓') : ''}
            </button>
          ))}
        </div>
        {namespaces.filter((n) => !ns || n.id === ns).map((n) => {
          const mine = rows.filter((r) => r.t.namespace === n.id)
          const q = query.trim().toLowerCase()
          const views = (model.views ?? []).filter((v) => v.namespace === n.id && (!q || v.name.toLowerCase().includes(q)))
          if (!mine.length && !views.length) return null
          return (
            <div key={n.id}>
              <div className="sf-nshead">
                <span className="sf-caption">namespace</span>
                <span className="sf-ns">{ix.path(n.id)}</span>
                <span className="sf-muted">{mine.length} tables{views.length ? ` · ${views.length} views` : ''}</span>
              </div>
              {views.map((v) => (
                <button key={v.id} type="button" className="sf-trow" onClick={() => go('table', v.id)}>
                  <span className="sf-tname">
                    <span className="sf-mono sf-strong">{v.name}</span>
                    {v.comment && <span className="sf-muted sf-ellipsis">{v.comment}</span>}
                  </span>
                  <span className="sf-fam"><span className="sf-dot" style={{ background: '#7fb2ff' }} />view</span>
                  <span className="sf-num">{v.columns?.length || ''}</span>
                  <span className="sf-num" />
                  <span className="sf-mono sf-type">{v.options?.postgres?.materialized ? 'materialized' : ''}</span>
                  <span className="sf-muted sf-right">reads {v.reads?.length ?? 0}</span>
                </button>
              ))}
              {mine.map((r) => (
                <button key={r.t.id} type="button" className="sf-trow" onClick={() => go('table', r.t.id)}>
                  <span className="sf-tname">
                    <span className="sf-mono sf-strong">{r.t.name}{r.copies ? <span className="sf-muted"> ×{r.copies + 1}</span> : null}</span>
                    {r.t.comment && <span className="sf-muted sf-ellipsis">{r.t.comment}</span>}
                  </span>
                  <span className="sf-fam"><span className="sf-dot" style={{ background: r.fam?.color }} />{r.fam?.name}</span>
                  <span className="sf-num">{r.cols}</span>
                  <span className="sf-num sf-nested">{r.nestedN || ''}</span>
                  <span className="sf-mono sf-type">{r.partition}</span>
                  <span className="sf-muted sf-right">{r.out} out · {r.into} in</span>
                </button>
              ))}
            </div>
          )
        })}
      </div>
      <span className="sf-muted">{rows.length === total ? `${total} tables. Click one to open it.` : `${rows.length} of ${total} tables`}</span>
    </div>
  )
}
