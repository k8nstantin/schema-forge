// Map: the schema as families, in columns from left to right by who refers to whom, a line for each pair with how
// many links it carries. A line that skips a column runs in a lane under the cards. Click a family for its own link
// diagram: its tables in the middle, the families that refer to it on the left, the ones it refers to on the right.

import { useMemo } from 'react'

import { LinkDiagram, type Card, type Line, type Row } from '../diagram/LinkDiagram'
import { useWorkbench, type Family, type Index } from '../state'

const CW = 230, GAP = 120, H = 64, VG = 14, TOP = 40, LANE = 16, MAX_ROWS = 40

interface Pair { from: string; to: string; n: number }

/// Links between families, one per ordered pair, with their count.
function pairs(ix: Index): Pair[] {
  const m = new Map<string, Pair>()
  for (const links of ix.out.values()) for (const l of links) {
    const a = ix.familyOf(l.from)?.key, b = ix.familyOf(l.to)?.key
    if (!a || !b || a === b) continue
    const k = `${a}\n${b}`
    if (!m.has(k)) m.set(k, { from: a, to: b, n: 0 })
    m.get(k)!.n++
  }
  return [...m.values()]
}

/// Columns: a family stands left of the families it mostly refers to. Longest path to a pure target, cycles cut.
function columns(keys: string[], ps: Pair[]): Map<string, number> {
  const n = (a: string, b: string) => ps.find((p) => p.from === a && p.to === b)?.n ?? 0
  const next = new Map<string, string[]>(keys.map((k) => [k, []]))
  for (const p of ps) if (p.n > n(p.to, p.from) || (p.n === n(p.to, p.from) && p.from < p.to)) next.get(p.from)!.push(p.to)
  const depth = new Map<string, number>()
  const walking = new Set<string>()
  const walk = (k: string): number => {
    if (depth.has(k)) return depth.get(k)!
    if (walking.has(k)) return 0
    walking.add(k)
    const d = Math.max(-1, ...next.get(k)!.map(walk)) + 1
    walking.delete(k)
    depth.set(k, d)
    return d
  }
  keys.forEach(walk)
  const most = Math.max(0, ...depth.values())
  return new Map(keys.map((k) => [k, most - depth.get(k)!]))
}

export function MapView({ family }: { family?: string }) {
  const { ix } = useWorkbench()
  const fam = family ? ix.families.get(family) : undefined
  return fam ? <FamilyLinks fam={fam} /> : <Overview />
}

function Overview() {
  const { name, ix, go } = useWorkbench()
  const { cards, lines, width, height, unlinked } = useMemo(() => {
    const ps = pairs(ix)
    const linked = [...ix.families.values()].filter((f) => ps.some((p) => p.from === f.key || p.to === f.key))
    const col = columns(linked.map((f) => f.key), ps)
    const byCol: Family[][] = []
    for (const f of linked) (byCol[col.get(f.key)!] ??= []).push(f)
    const at = new Map<string, { x: number; y: number }>()
    byCol.forEach((list, c) => list.forEach((f, i) => at.set(f.key, { x: 24 + c * (CW + GAP), y: TOP + i * (H + VG) })))
    const bottom = Math.max(TOP, ...[...at.values()].map((p) => p.y + H))
    let lane = 0
    const lines = ps.map((p) => {
      const a = at.get(p.from)!, b = at.get(p.to)!
      const adjacent = col.get(p.to)! === col.get(p.from)! + 1
      if (adjacent) {
        const y1 = a.y + H / 2, y2 = b.y + H / 2, x1 = a.x + CW, x2 = b.x - 2, m = (x1 + x2) / 2
        return { p, d: `M${x1} ${y1} C${m} ${y1} ${m} ${y2} ${x2} ${y2}`, head: `M${x2 + 1} ${y2} L${x2 - 8} ${y2 - 5} L${x2 - 8} ${y2 + 5} Z`, lx: m, ly: (y1 + y2) / 2 }
      }
      // Under the cards, never through them: out of the source's right side, down the gap after its column, along a
      // lane of its own, up the gap before the target's column, into its left side.
      const i = lane++
      const y = bottom + 24 + i * LANE
      const y1 = a.y + H / 2, y2 = b.y + H / 2
      const shift = 14 + (i % 8) * 7
      const g1 = a.x + CW + shift, g2 = b.x - shift, x2 = b.x - 2
      const r = 6, dir = g2 >= g1 ? 1 : -1
      const d = `M${a.x + CW} ${y1} L${g1 - r} ${y1} Q${g1} ${y1} ${g1} ${y1 + r} L${g1} ${y - r} Q${g1} ${y} ${g1 + dir * r} ${y} `
        + `L${g2 - dir * r} ${y} Q${g2} ${y} ${g2} ${y - r} L${g2} ${y2 + r} Q${g2} ${y2} ${g2 + r} ${y2} L${x2} ${y2}`
      return { p, d, head: `M${x2 + 1} ${y2} L${x2 - 8} ${y2 - 5} L${x2 - 8} ${y2 + 5} Z`, lx: (g1 + g2) / 2, ly: y }
    })
    const width = 24 + Math.max(1, byCol.length) * (CW + GAP) - GAP + 24
    const height = bottom + 24 + lane * LANE + 24
    const unlinked = [...ix.families.values()].filter((f) => !at.has(f.key))
    return { cards: linked.map((f) => ({ f, ...at.get(f.key)! })), lines, width, height, unlinked }
  }, [ix])

  return (
    <div className="sf-page">
      <div className="sf-row-between">
        <div className="sf-nstitle">
          <span className="sf-caption">schema</span>
          <h2 className="sf-ns sf-ns-big">{name}</h2>
          <span className="sf-muted">{ix.families.size} families · referring families on the left, what they refer to on the right</span>
        </div>
        <span className="sf-muted sf-small">Click a family to see how it links.</span>
      </div>
      {cards.length > 0 ? (
        <div className="sf-diagram-frame">
          <div className="sf-diagram" style={{ width, height }}>
            <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden="true">
              {lines.map(({ p, d, head }) => (
                <g key={`${p.from}>${p.to}`}>
                  <path d={d} className="sf-line" style={{ stroke: ix.families.get(p.from)!.color }} />
                  <path d={head} className="sf-head" style={{ fill: ix.families.get(p.from)!.color }} />
                </g>
              ))}
              {lines.map(({ p, lx, ly }) => (
                <g key={`n${p.from}>${p.to}`} className="sf-count">
                  <rect x={lx - 13} y={ly - 9} width={26} height={18} rx={9} />
                  <text x={lx} y={ly + 4} textAnchor="middle">{p.n}</text>
                </g>
              ))}
            </svg>
            {cards.map(({ f, x, y }) => (
              <button key={f.key} type="button" className="sf-dcard sf-famnode" onClick={() => go('map', f.key)} title={`${ix.path(f.namespace)} › ${f.name}`} style={{ left: x, top: y, width: CW, height: H, borderLeftColor: f.color }}>
                <span className="sf-dcard-sub">{ix.path(f.namespace)}</span>
                <span className="sf-dcard-top">
                  <span className="sf-dcard-title" style={{ color: f.color }}>{f.name}</span>
                  <span className="sf-dcard-meta">{f.tables.length} tables</span>
                </span>
              </button>
            ))}
          </div>
        </div>
      ) : (
        <span className="sf-muted">No links between families found.</span>
      )}
      {unlinked.length > 0 && (
        <div className="sf-col">
          <span className="sf-caption">Not linked to other families · {unlinked.length}</span>
          <div className="sf-chips">
            {unlinked.map((f) => (
              <button key={f.key} type="button" className="sf-chip" onClick={() => go('map', f.key)}>
                <span className="sf-dot" style={{ background: f.color }} />{ix.path(f.namespace)} › {f.name} · {f.tables.length}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

function FamilyLinks({ fam }: { fam: Family }) {
  const { name, ix, go } = useWorkbench()
  const mine = new Set(fam.tables.map((t) => t.id))
  const tname = (id: string) => ix.tables.get(id)?.name ?? id
  const colName = (c: string) => ix.columns.get(c)?.column.name ?? c
  // Links crossing the family's edge, by the other family.
  const ins = fam.tables.flatMap((t) => ix.into.get(t.id) ?? []).filter((l) => !mine.has(l.from) && ix.familyOf(l.from))
  const outs = fam.tables.flatMap((t) => ix.out.get(t.id) ?? []).filter((l) => !mine.has(l.to) && ix.familyOf(l.to))
  const inside = fam.tables.flatMap((t) => ix.out.get(t.id) ?? []).filter((l) => mine.has(l.to)).length
  const group = (ls: typeof ins, side: 'from' | 'to') => {
    const m = new Map<string, typeof ins>()
    for (const l of ls) {
      const k = ix.familyOf(l[side])!.key
      if (!m.has(k)) m.set(k, [])
      m.get(k)!.push(l)
    }
    return [...m].sort((a, b) => b[1].length - a[1].length)
  }
  const card = ([k, ls]: [string, typeof ins], side: 'from' | 'to'): Card => {
    const f = ix.families.get(k)!
    const sample = [...new Set(ls.map((l) => (side === 'from' ? `${tname(l.from)}.${colName(l.column)}` : tname(l.to))))]
    return { key: k, title: f.name, meta: `${ls.length} ${ls.length === 1 ? 'link' : 'links'}`, sub: `${ix.path(f.namespace)} · ${sample.slice(0, 2).join(', ')}${sample.length > 2 ? '…' : ''}`, color: f.color, onClick: () => go('map', k) }
  }
  const left = group(ins, 'from').map((g) => card(g, 'from'))
  const right = group(outs, 'to').map((g) => card(g, 'to'))
  // The middle: tables that link across first (gold when they refer out), then the rest, alphabetically.
  const crossing = new Set([...ins.map((l) => l.to), ...outs.map((l) => l.from)])
  const ordered = [...fam.tables].sort((a, b) => Number(crossing.has(b.id)) - Number(crossing.has(a.id)) || a.name.localeCompare(b.name))
  const shown = ordered.slice(0, MAX_ROWS)
  const outFrom = new Set(outs.map((l) => l.from))
  const rows: Row[] = shown.map((t) => ({ key: t.id, name: t.name, note: `${t.columns.length} cols`, joins: outFrom.has(t.id), onClick: () => go('table', t.id) }))
  const onRow = (id: string) => (shown.some((t) => t.id === id) ? id : undefined)
  const seen = new Set<string>()
  const lines: Line[] = []
  for (const l of ins) {
    const k = `l${ix.familyOf(l.from)!.key}>${l.to}`
    if (!seen.has(k)) { seen.add(k); lines.push({ side: 'left', card: ix.familyOf(l.from)!.key, row: onRow(l.to) }) }
  }
  for (const l of outs) {
    const k = `r${l.from}>${ix.familyOf(l.to)!.key}`
    if (!seen.has(k)) { seen.add(k); lines.push({ side: 'right', card: ix.familyOf(l.to)!.key, row: onRow(l.from) }) }
  }
  return (
    <div className="sf-page">
      <nav className="sf-crumbs" aria-label="Where this family is">
        <button type="button" className="sf-link" onClick={() => go('map')}>{name}</button>
        <span>›</span>
        <button type="button" className="sf-nspill" onClick={() => go('categories')}>{ix.path(fam.namespace)}</button>
        <span>›</span>
        <span className="sf-strong">{fam.name}</span>
      </nav>
      <div className="sf-titlerow">
        <span className="sf-title" style={{ color: fam.color }}>{fam.name}</span>
        <span className="sf-muted">
          {fam.tables.length} tables{fam.copies ? ` (+${fam.copies} copies)` : ''} · {ins.length} links in, {outs.length} out, {inside} inside
        </span>
        <button type="button" className="sf-chip" onClick={() => go('map')}>Back to the whole schema</button>
      </div>
      <LinkDiagram
        leftHead={`Refer to it · ${left.length} ${left.length === 1 ? 'family' : 'families'}`}
        rightHead={`It refers to · ${right.length} ${right.length === 1 ? 'family' : 'families'}`}
        left={left}
        right={right}
        lines={lines}
        center={{ caption: 'family', title: fam.name, color: fam.color, rows }}
        empty="No links to other families."
      />
      {ordered.length > MAX_ROWS && <span className="sf-muted">Showing {MAX_ROWS} of {ordered.length} tables, those that link across first. The rest are in Categories.</span>}
    </div>
  )
}
