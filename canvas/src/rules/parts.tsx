// Pieces the rules views share: a rule's strength, a pass/break bar, the findings as references, a type map.

import type { Finding, Lane, Rule, Tally, TypeMap } from '../model'
import { tableRef, useWorkbench } from '../state'

/// The exception that switches every rule off: rules are optional, for a schema, a group, any level.
export const ALL = '*'

/// The lanes, in the order the catalog shows them.
export const LANES: [Lane, string][] = [
  ['shared', 'Every database'],
  ['mysql', 'MySQL'],
  ['postgres', 'PostgreSQL'],
  ['iceberg', 'Iceberg'],
  ['between', 'Between databases'],
]

export function Strength({ rule }: { rule: Rule }) {
  return <span className={`sf-strength sf-${rule.strength}`}>{rule.strength === 'must' ? 'Must' : 'Should'}</span>
}

/// Passes in green, breaks in red, with the numbers in words beside it.
export function TallyBar({ tally, preview }: { tally?: Tally; preview?: boolean }) {
  if (!tally) return <span className="sf-muted sf-small">not linked</span>
  const pass = Math.max(0, tally.checked - tally.breaks)
  const pct = tally.checked ? (pass / tally.checked) * 100 : 100
  return (
    <span className="sf-tally">
      <span className="sf-tallybar" aria-hidden="true">
        <span className="sf-pass" style={{ width: `${pct}%` }} />
        <span className="sf-break" style={{ width: `${100 - pct}%` }} />
      </span>
      <span className={tally.breaks ? 'sf-breaks' : 'sf-passes'}>
        {tally.checked === 0
          ? 'nothing to check'
          : tally.breaks
            ? `${preview ? '+' : ''}${tally.breaks.toLocaleString()} ${tally.breaks === 1 ? 'break' : 'breaks'}${preview ? ' if linked' : ''}`
            : `all ${tally.checked.toLocaleString()} pass`}
      </span>
    </span>
  )
}

/// Findings as references you can open and point at: `@orders.total: holds money as double`.
export function Findings({ findings, limit = 60 }: { findings: Finding[]; limit?: number }) {
  const { ix, go, point, catalog } = useWorkbench()
  if (!findings.length) return null
  return (
    <div className="sf-findings">
      {findings.slice(0, limit).map((f, i) => {
        const col = f.column ? ix.columns.get(f.column)?.column.name : undefined
        return (
          <button key={i} type="button" className="sf-finding" onClick={() => { point(f.column ? { kind: 'column', table: f.table, column: f.column } : { kind: 'table', table: f.table }); go('table', f.table) }}>
            <span className="sf-mono sf-ref-inline">{tableRef(ix, f.table)}{col ? `.${col}` : ''}</span>
            <span>{f.message}</span>
            <span className="sf-muted sf-small">{catalog.rules.find((r) => r.id === f.rule)?.title}</span>
          </button>
        )
      })}
      {findings.length > limit && <span className="sf-muted sf-small">and {(findings.length - limit).toLocaleString()} more</span>}
    </div>
  )
}

const GRADE: Record<string, string> = { exact: 'Exact', widened: 'Widened', decide: 'Decide', lossy: 'Lossy', none: 'No type' }

export function MapTable({ map }: { map: TypeMap }) {
  return (
    <div className="sf-coltable">
      <div className="sf-maprow sf-thead"><span>{map.from}</span><span>{map.to}</span><span>Grade</span><span>Why, and the fix</span></div>
      {map.rows.map((r, i) => (
        <div key={i} className="sf-maprow">
          <span className="sf-mono sf-type">{r.from}</span>
          <span className="sf-mono">{r.to}</span>
          <span className={`sf-grade sf-grade-${r.grade}`}>{GRADE[r.grade]}</span>
          <span className="sf-muted">{r.why}</span>
        </div>
      ))}
    </div>
  )
}

/// The type map a compatibility rule reads, if `id` is one.
export function mapOf(maps: TypeMap[], id: string): TypeMap | undefined {
  const m = /^compat\.([a-z]+-[a-z]+)/.exec(id)
  return m ? maps.find((x) => x.id === m[1]) : undefined
}
