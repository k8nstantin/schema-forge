// Map, as the "Perspective · Map" board draws it: the whole schema as families in columns, each family left of the
// families it refers to, so the roots everything leads to are on the right; a line counts the links it stands for.
// A family opens to its own diagram: who refers into it, its tables, what it refers to.

import { useMemo } from 'react'

import { LinkDiagram, type Card, type Line, type Row } from '../diagram/LinkDiagram'
import { useWorkbench, type Family, type Index } from '../state'

// The board's overview: 196 wide cards, 76 between columns, 18 between rows, captions above.
const CW = 196, GAP = 76, H = 64, VG = 18, TOP = 48, LANE = 30, MAX_ROWS = 40

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

export function MapScreen({ family }: { family?: string }) {
  const { ix } = useWorkbench()
  const fam = family ? ix.families.get(family) : undefined
  return fam ? <FamilyLinks fam={fam} /> : <Overview />
}

function Overview() {
  const { name, ix, go } = useWorkbench()
  const { cards, lines, width, height, unlinked, lastX } = useMemo(() => {
    const ps = pairs(ix)
    const linked = [...ix.families.values()].filter((f) => ps.some((p) => p.from === f.key || p.to === f.key))
    const col = columns(linked.map((f) => f.key), ps)
    const byCol: Family[][] = []
    for (const f of linked) (byCol[col.get(f.key)!] ??= []).push(f)
    const tallest = Math.max(1, ...byCol.map((c) => c?.length ?? 0))
    const at = new Map<string, { x: number; y: number }>()
    byCol.forEach((list, c) => {
      const y0 = TOP + ((tallest - list.length) * (H + VG)) / 2
      list.forEach((f, i) => at.set(f.key, { x: 24 + c * (CW + GAP), y: y0 + i * (H + VG) }))
    })
    const bottom = TOP + tallest * (H + VG) - VG
    let lane = 0
    const lines = ps.map((p) => {
      const a = at.get(p.from)!, b = at.get(p.to)!
      const y1 = a.y + H / 2, y2 = b.y + H / 2
      const head = `M${b.x - 1} ${y2} L${b.x - 10} ${y2 - 5} L${b.x - 10} ${y2 + 5} Z`
      if (col.get(p.to)! - col.get(p.from)! === 1) {
        const x1 = a.x + CW, x2 = b.x - 2, m = (x1 + x2) / 2
        return { p, d: `M${x1} ${y1} C${m} ${y1} ${m} ${y2} ${x2} ${y2}`, head, lx: m, ly: (y1 + y2) / 2 }
      }
      // One that skips columns runs in its own lane under the cards, so it never passes behind one.
      const ly = bottom + 34 + lane * LANE
      lane += 1
      const x1 = a.x + CW, x2 = b.x - 2
      const d = `M${x1} ${y1} C${x1 + 36} ${y1} ${x1 + 36} ${ly} ${x1 + 72} ${ly} L${x2 - 72} ${ly} C${x2 - 36} ${ly} ${x2 - 36} ${y2} ${x2} ${y2}`
      return { p, d, head, lx: (x1 + x2) / 2, ly }
    })
    const width = 24 + Math.max(1, byCol.length) * (CW + GAP) - GAP + 24
    const height = bottom + 34 + lane * LANE + 20
    const unlinked = [...ix.families.values()].filter((f) => !at.has(f.key))
    return { cards: linked.map((f) => ({ f, ...at.get(f.key)! })), lines, width, height, unlinked, lastX: 24 + (byCol.length - 1) * (CW + GAP) }
  }, [ix])

  return (
    <main className="d-map-main">
      <div className="d-row" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
        <nav aria-label="Where you are" className="d-crumbs">
          <button type="button" className="d-crumb" onClick={() => go('categories')}>{name}</button><span className="d-slash">›</span>
          <span style={{ color: 'var(--d-bright)' }}>Map</span>
        </nav>
        <span className="d-xsmall d-soft">Click a family to see its tables and exactly how they link.</span>
      </div>
      <div className="d-col d-gap-4">
        <span className="d-map-title">The whole schema, as it links</span>
        <span className="d-small d-soft" style={{ maxWidth: 900 }}>
          Families in columns: each family sits left of the families it refers to, so the roots everything leads to are on the right. A line counts the links it stands for. Click a family to open it.
        </span>
      </div>
      {cards.length > 0 ? (
        <div className="d-map-frame">
          <div style={{ position: 'relative', width, height, margin: '0 auto' }}>
            <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} style={{ position: 'absolute', left: 0, top: 0 }} aria-hidden="true">
              {lines.map(({ p, d, head }) => (
                <g key={`${p.from}>${p.to}`}>
                  <path d={d} fill="none" stroke="#cc66ff" strokeWidth={p.n >= 15 ? 4 : 1.8} opacity={p.n >= 15 ? 0.55 : 0.8} />
                  <path d={head} fill="#cc66ff" />
                </g>
              ))}
            </svg>
            <span className="d-map-cap" style={{ left: 24 }}>Refers to the others</span>
            {lastX > 24 && <span className="d-map-cap" style={{ left: lastX }}>Everything leads here</span>}
            {lines.map(({ p, lx, ly }) => (
              <span key={`n${p.from}>${p.to}`} className="d-map-count" style={{ left: lx - 16, top: ly - 11 }}>{p.n}</span>
            ))}
            {cards.map(({ f, x, y }) => (
              <button key={f.key} type="button" className="d-map-card" onClick={() => go('map', f.key)}
                style={{ left: x, top: y, width: CW, height: H, borderLeftColor: f.color }}>
                <span className="d-row" style={{ justifyContent: 'space-between', alignItems: 'baseline', gap: 8, flexWrap: 'nowrap' }}>
                  <span className="d-map-fam" style={{ color: f.color }}>{f.name}</span>
                  <span className="d-soft" style={{ fontSize: 12, flexShrink: 0 }}>{f.tables.length} tables</span>
                </span>
                <span className="d-map-ns">{ix.path(f.namespace)}</span>
              </button>
            ))}
          </div>
        </div>
      ) : (
        <span className="d-soft">No links between families found.</span>
      )}
      {unlinked.length > 0 && (
        <div className="d-col d-gap-8">
          <span className="d-caps d-caps-sm">Not linked to other families · {unlinked.length}</span>
          <div className="d-row d-gap-8">
            {unlinked.map((f) => (
              <button key={f.key} type="button" className="d-chip d-chip-btn" onClick={() => go('map', f.key)}>
                <span className="d-famdot" style={{ background: f.color, display: 'inline-block', marginRight: 6 }} />{f.name} · {f.tables.length}
              </button>
            ))}
          </div>
        </div>
      )}
    </main>
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
    <main className="d-map-main">
      <div className="d-row" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
        <nav aria-label="Where you are" className="d-crumbs">
          <button type="button" className="d-crumb" onClick={() => go('map')}>{name}</button><span className="d-slash">›</span>
          <button type="button" className="d-crumb" onClick={() => go('map')}>Map</button><span className="d-slash">›</span>
          <span style={{ color: 'var(--d-bright)' }}>{fam.name}</span>
        </nav>
        <span className="d-xsmall d-soft">Click a family on either side to open it; a table in the middle opens it.</span>
      </div>
      <div className="d-col d-gap-4">
        <span className="d-map-title">{fam.name} · {fam.tables.length} tables</span>
        <span className="d-small d-soft" style={{ maxWidth: 900 }}>
          In {ix.path(fam.namespace)}{fam.copies ? `, with ${fam.copies} copies` : ''}: {ins.length} links in, {outs.length} out, {inside} inside.
        </span>
      </div>
      <button type="button" className="d-btn d-btn-line d-btn-sm" onClick={() => go('map')}>← Back to the whole schema</button>
      <LinkDiagram
        leftHead={`Refer into it · ${left.length}`}
        rightHead={`It refers to · ${right.length}`}
        left={left}
        right={right}
        lines={lines}
        center={{ caption: ix.path(fam.namespace), title: fam.name, color: fam.color, rows }}
        empty="No links to other families."
      />
      {ordered.length > MAX_ROWS && <span className="d-xsmall d-soft">Showing {MAX_ROWS} of {ordered.length} tables, those that link across first. The rest are in Categories.</span>}
    </main>
  )
}
