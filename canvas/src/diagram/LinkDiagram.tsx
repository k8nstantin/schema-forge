// The link diagram: one thing in the middle, what refers to it on the left, what it refers to on the right, and a
// curved line for each link, landing on the exact row it joins. The Table and the Map draw with it.

import type { ReactNode } from 'react'

export interface Card {
  key: string
  title: string
  meta?: string
  sub?: string
  color?: string
  /// An exception: drawn gold and dashed.
  tone?: 'off'
  onClick?: () => void
}

export interface Row {
  key: string
  name: string
  note?: string
  /// A row that joins: drawn gold.
  joins?: boolean
  onClick?: () => void
}

export interface Line {
  side: 'left' | 'right'
  card: string
  /// The middle's row the line lands on; the middle's header when left out.
  row?: string
  /// `above`: reaches it from a wider level (quiet); `off`: switched off (gold, dashed, a bar for a head).
  tone?: 'above' | 'off'
}

const CW = 270, GAP = 150, H = 52, VG = 10, TOP = 44, HEAD = 46, ROW = 26

export function LinkDiagram(props: {
  leftHead: string
  rightHead: string
  left: Card[]
  right: Card[]
  center: { caption: string; title: string; color: string; rows: Row[] }
  lines: Line[]
  empty?: ReactNode
}) {
  const { left, right, center, lines } = props
  const colH = (n: number) => (n ? n * (H + VG) - VG : 0)
  const centerH = HEAD + center.rows.length * ROW + 10
  const bodyH = Math.max(colH(left.length), centerH, colH(right.length), 110)
  const xL = 24, xC = xL + CW + GAP, xR = xC + CW + GAP
  const yL = TOP + (bodyH - colH(left.length)) / 2
  const yC = TOP + (bodyH - centerH) / 2
  const yR = TOP + (bodyH - colH(right.length)) / 2
  const width = xR + CW + 24, height = TOP + bodyH + 24
  const rowY = (k?: string) => {
    const i = k ? center.rows.findIndex((r) => r.key === k) : -1
    return i < 0 ? yC + HEAD / 2 : yC + HEAD + i * ROW + ROW / 2 + 4
  }
  const curve = (x1: number, y1: number, x2: number, y2: number) => {
    const m = (x1 + x2) / 2
    return `M${x1} ${y1} C${m} ${y1} ${m} ${y2} ${x2} ${y2} `
  }
  const head = (x: number, y: number) => `M${x} ${y} L${x - 9} ${y - 5} L${x - 9} ${y + 5} Z `
  const d = { line: '', above: '', off: '' }
  const h = { line: '', above: '', off: '' }
  for (const l of lines) {
    const tone = l.tone ?? 'line'
    if (l.side === 'left') {
      const i = left.findIndex((c) => c.key === l.card)
      if (i < 0) continue
      const y2 = rowY(l.row)
      d[tone] += curve(xL + CW, yL + i * (H + VG) + H / 2, xC - 2, y2)
      h[tone] += tone === 'off' ? `M${xC - 3} ${y2 - 8} L${xC - 3} ${y2 + 8} ` : head(xC - 1, y2)
    } else {
      const i = right.findIndex((c) => c.key === l.card)
      if (i < 0) continue
      const y2 = yR + i * (H + VG) + H / 2
      d[tone] += curve(xC + CW, rowY(l.row), xR - 2, y2)
      h[tone] += tone === 'off' ? `M${xR - 3} ${y2 - 8} L${xR - 3} ${y2 + 8} ` : head(xR - 1, y2)
    }
  }
  const card = (c: Card, x: number, y: number) => (
    <button key={c.key} type="button" className={`sf-dcard${c.tone === 'off' ? ' sf-dcard-off' : ''}`} onClick={c.onClick} title={c.sub ? `${c.title} ${c.sub}` : c.title} style={{ left: x, top: y, width: CW, height: H, borderLeftColor: c.color }}>
      <span className="sf-dcard-top">
        <span className="sf-dcard-title">{c.title}</span>
        {c.meta && <span className="sf-dcard-meta">{c.meta}</span>}
      </span>
      {c.sub && <span className="sf-dcard-sub">{c.sub}</span>}
    </button>
  )
  return (
    <div className="sf-diagram-frame">
      <div className="sf-diagram" style={{ width, height }}>
        <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden="true">
          <path d={d.above} className="sf-line sf-above" />
          <path d={h.above} className="sf-head sf-above" />
          <path d={d.line} className="sf-line" />
          <path d={h.line} className="sf-head" />
          <path d={d.off} className="sf-line sf-off" />
          <path d={h.off} className="sf-bar" />
        </svg>
        <span className="sf-dhead" style={{ left: xL }}>{props.leftHead}</span>
        <span className="sf-dhead" style={{ left: xR }}>{props.rightHead}</span>
        {left.map((c, i) => card(c, xL, yL + i * (H + VG)))}
        {right.map((c, i) => card(c, xR, yR + i * (H + VG)))}
        <div className="sf-dcenter" style={{ left: xC, top: yC, width: CW, height: centerH, borderColor: center.color }}>
          <span className="sf-dcenter-caption">{center.caption}</span>
          <span className="sf-dcenter-title" style={{ color: center.color }}>{center.title}</span>
          {center.rows.map((r) => (
            <button key={r.key} type="button" className={`sf-drow${r.joins ? ' sf-joins' : ''}`} style={{ height: ROW }} onClick={r.onClick}>
              <span>{r.name}</span>
              {r.note && <span className="sf-drow-note">{r.note}</span>}
            </button>
          ))}
        </div>
      </div>
      {!left.length && !right.length && props.empty && <div className="sf-dempty">{props.empty}</div>}
    </div>
  )
}
