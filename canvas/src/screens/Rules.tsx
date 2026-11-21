// Rules, as the "Perspective · Rules" and "Perspective · Rule" boards draw them. The landing: the rules the schema
// follows, by pack, each with how it holds, what passes and what breaks. A rule: the rule tree (packs first), where
// the rule sits, what it is made of, and what breaks it, rolled up from every rule under it.

import { useMemo, useState } from 'react'

import type { Catalog, Enforce, Finding, Rule, RuleLink } from '../model'
import { useWorkbench } from '../state'

/// The checks a rule is made of: itself when it checks the schema directly.
function leavesOf(cat: Catalog, id: string, seen = new Set<string>()): string[] {
  if (seen.has(id)) return []
  seen.add(id)
  const r = cat.rules.find((x) => x.id === id)
  return r?.rules?.length ? r.rules.flatMap((k) => leavesOf(cat, k, seen)) : [id]
}

const isPack = (r?: Rule) => !!r?.rules?.length

/// How a linked rule holds: as linked, else by its own default.
function howHeld(link: RuleLink | undefined, r: Rule | undefined): Enforce {
  return link?.enforce ?? (r?.strength === 'must' ? 'hard' : 'soft')
}

export function RulesHome() {
  const { name, catalog, rules, go } = useWorkbench()
  const [filter, setFilter] = useState<'all' | 'breaks' | 'hard'>('all')
  const report = rules.report
  const byId = (id: string) => catalog.rules.find((r) => r.id === id)
  // What the schema follows: every rule linked here or for every schema, packs opened into their checks.
  const linked = [...rules.global, ...rules.links].filter((l) => !l.off && l.rule !== '*')
  const groups = useMemo(() => {
    const seen = new Set<string>()
    const out: { id: string; title: string; about: string; link: RuleLink; checks: string[] }[] = []
    for (const l of linked) {
      const r = byId(l.rule)
      if (!r || seen.has(r.id)) continue
      seen.add(r.id)
      out.push({ id: r.id, title: r.title, about: r.why, link: l, checks: isPack(r) ? leavesOf(catalog, r.id) : [r.id] })
    }
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rules, catalog])
  const broken = new Set(groups.flatMap((g) => g.checks).filter((c) => (report.tallies[c]?.breaks ?? 0) > 0)).size
  const keep = (c: string, how: Enforce) =>
    filter === 'all' || (filter === 'breaks' && (report.tallies[c]?.breaks ?? 0) > 0) || (filter === 'hard' && how === 'hard')

  return (
    <main className="d-persp-main" style={{ gap: 20 }}>
      <div className="d-row" style={{ justifyContent: 'space-between', alignItems: 'flex-end' }}>
        <div className="d-col d-gap-4">
          <span className="d-caps d-caps-sm">The rules {name} follows</span>
          <span className="d-soft" style={{ maxWidth: 760 }}>
            <b style={{ color: 'var(--d-gold)' }}>Hard</b>: a change that breaks it is refused, the agent's and yours. <b style={{ color: 'var(--d-lilac)' }}>Soft</b>: the change lands and the break is listed here.
          </span>
        </div>
        <div className="d-row" style={{ gap: 6 }}>
          <button type="button" className="d-act" onClick={() => go('rules', 'catalog')}>Apply packs</button>
          <button type="button" className="d-act d-act-line" onClick={() => go('rules', 'catalog')}>Built-in packs</button>
          <button type="button" className="d-act" onClick={() => go('rules', 'goals')}>Start from a goal</button>
          <button type="button" className="d-act d-act-line" onClick={() => go('rules', 'level')}>Where rules apply</button>
          <button type="button" className="d-act d-act-line" onClick={() => go('rules', 'review')}>Review the agent's rules</button>
          {([['all', 'All rules'], ['breaks', `With breaks · ${broken}`], ['hard', 'Hard only']] as const).map(([k, label]) => (
            <button key={k} type="button" className={`d-nschip${filter === k ? ' d-nschip-on' : ''}`} onClick={() => setFilter(k)}>{label}</button>
          ))}
        </div>
      </div>

      {groups.length === 0 ? (
        <div className="d-panel" style={{ gap: 10 }}>
          <span className="d-strong">{name} follows no rules yet.</span>
          <span className="d-soft">A schema has none until you add them: apply a pack, or start from what the schema has to do.</span>
          <div className="d-row">
            <button type="button" className="d-btn" onClick={() => go('rules', 'catalog')}>Apply packs</button>
            <button type="button" className="d-btn d-btn-line" onClick={() => go('rules', 'goals')}>Start from a goal</button>
          </div>
        </div>
      ) : (
        <div className="d-tbl">
          <div className="d-rrow d-tbl-head d-rhead">
            <span>Rule</span><span>Holds</span><span>Result on {name}</span><span style={{ textAlign: 'right' }}>Breaks</span>
          </div>
          {groups.map((g) => {
            const rows = g.checks.map((c) => ({ c, r: byId(c), how: howHeld(g.link, byId(c)) })).filter(({ c, how }) => keep(c, how))
            if (!rows.length) return null
            return (
              <div key={g.id}>
                <div className="d-rpack">
                  <button type="button" className="d-rpack-name" onClick={() => go('rules', `rule:${g.id}`)}>{g.title}</button>
                  <span className="d-mono" style={{ fontSize: 12, color: 'var(--d-gold)' }}>@rule:{g.id}</span>
                  <span className="d-xsmall d-soft">{g.about}</span>
                </div>
                {rows.map(({ c, r, how }) => {
                  const t = report.tallies[c]
                  const checked = t?.checked ?? 0
                  const fail = t?.breaks ?? 0
                  const pass = Math.max(0, checked - fail)
                  const pct = checked ? (pass / checked) * 100 : 100
                  return (
                    <button key={`${g.id}-${c}`} type="button" className="d-rrow d-rline" onClick={() => go('rules', `rule:${c}`)}>
                      <span className="d-col" style={{ minWidth: 0 }}>
                        <span style={{ fontSize: 15, fontWeight: 600, color: 'var(--d-bright)' }}>{r?.title ?? c}</span>
                        <span className="d-mono" style={{ fontSize: 12, color: 'var(--d-gold)' }}>@rule:{c}</span>
                      </span>
                      <span className={`d-held d-held-${how}`}>{how === 'hard' ? 'Hard' : 'Soft'}</span>
                      <span className="d-col d-gap-4">
                        <span className="d-bar2"><span style={{ width: `${pct}%`, background: '#199e70' }} /><span style={{ width: `${100 - pct}%`, background: '#ff7a7a' }} /></span>
                        <span className="d-soft" style={{ fontSize: 12 }}>{!checked ? 'nothing to check yet' : fail ? `${pass.toLocaleString()} of ${checked.toLocaleString()} pass` : `all ${checked.toLocaleString()} pass`}</span>
                      </span>
                      <span style={{ textAlign: 'right', fontSize: 14, fontWeight: 600, color: fail ? '#ff7a7a' : '#3fc98a' }}>{fail ? `${fail} ${fail === 1 ? 'break' : 'breaks'}` : 'none'}</span>
                    </button>
                  )
                })}
              </div>
            )
          })}
        </div>
      )}
      <span className="d-xsmall d-soft">Checked against {name} as it is now. Click a rule to see exactly what breaks it.</span>
    </main>
  )
}

export function RuleScreen({ id }: { id: string }) {
  const { name, catalog, rules, ix, go, point } = useWorkbench()
  const [openRoots, setOpenRoots] = useState<Set<string>>(new Set())
  const byId = (k: string) => catalog.rules.find((r) => r.id === k)
  const findings = rules.report.findings
  const linked = [...rules.global, ...rules.links].filter((l) => !l.off)
  const applied = new Set(linked.map((l) => l.rule))
  const kids = (k: string) => byId(k)?.rules ?? []
  const parents = (k: string) => catalog.rules.filter((r) => r.rules?.includes(k)).map((r) => r.id)
  const fails = (k: string): Finding[] => { const ls = new Set(leavesOf(catalog, k)); return findings.filter((f) => ls.has(f.rule)) }
  const checked = (k: string) => leavesOf(catalog, k).reduce((n, l) => n + (rules.report.tallies[l]?.checked ?? 0), 0)
  // Roots: packs nothing holds. Those the schema applies come first and open; the rest stay shut until opened.
  const roots = catalog.rules.filter((r) => isPack(r) && !parents(r.id).length)
    .sort((a, b) => Number(applied.has(b.id)) - Number(applied.has(a.id)) || a.title.localeCompare(b.title))
  const rule = byId(id)
  const up = parents(id)
  const down = kids(id)
  const mine = fails(id)
  const pathTo = (k: string, guard = 0): string[] => { const p = parents(k)[0]; return p && guard < 20 ? [...pathTo(p, guard + 1), k] : [k] }
  const path = pathTo(id)
  const kind = isPack(rule) ? (up.length ? 'Rule of rules' : 'Root rule') : 'Rule'
  const link = linked.find((l) => l.rule === id)
  const tablesHit = new Set(mine.map((f) => f.table)).size
  const fromRules = new Set(mine.map((f) => f.rule)).size
  const tname = (t: string) => ix.tables.get(t)?.name ?? t
  const cname = (c?: string) => (c ? ix.columns.get(c)?.column.name ?? c : '')

  type Node = { k: string; depth: number }
  const tree: Node[] = []
  const walk = (k: string, depth: number, seen: Set<string>) => {
    if (seen.has(k)) return
    tree.push({ k, depth })
    const open = depth > 0 || applied.has(k) || openRoots.has(k) || path.includes(k)
    if (open) for (const c of kids(k)) walk(c, depth + 1, new Set([...seen, k]))
  }
  roots.forEach((r) => walk(r.id, 0, new Set()))

  // The diagram: parents on the left, the rule in the middle, what it is made of on the right.
  const CW = 270, GAP = 140, H = 58, VG = 10, TOP = 44, CH = 150
  const xL = 24, xC = xL + CW + GAP, xR = xC + CW + GAP
  const colH = (n: number) => (n ? n * (H + VG) - VG : 0)
  const bodyH = Math.max(colH(up.length), CH, colH(down.length), 150)
  const yL = TOP + (bodyH - colH(up.length)) / 2, yC = TOP + (bodyH - CH) / 2, yR = TOP + (bodyH - colH(down.length)) / 2
  const dw = xR + CW + 24, dh = TOP + bodyH + 24
  const curve = (x1: number, y1: number, x2: number, y2: number) => { const m = (x1 + x2) / 2; return `M${x1} ${y1} C${m} ${y1} ${m} ${y2} ${x2} ${y2} ` }
  const upD = up.map((_, i) => curve(xL + CW, yL + i * (H + VG) + H / 2, xC - 2, yC + CH / 2)).join('')
  const failD = down.filter((k) => fails(k).length).map((k) => curve(xC + CW, yC + CH / 2, xR - 2, yR + down.indexOf(k) * (H + VG) + H / 2)).join('')
  const passD = down.filter((k) => !fails(k).length).map((k) => curve(xC + CW, yC + CH / 2, xR - 2, yR + down.indexOf(k) * (H + VG) + H / 2)).join('')
  const node = (k: string, x: number, y: number) => {
    const n = fails(k).length
    const r = byId(k)
    return (
      <button key={`${x}-${k}`} type="button" className="d-rnode" onClick={() => go('rules', `rule:${k}`)}
        style={{ left: x, top: y, width: CW, height: H, borderColor: n ? '#7a2f36' : '#1f6b4a' }}>
        <span className="d-row" style={{ justifyContent: 'space-between', gap: 8, flexWrap: 'nowrap', alignItems: 'baseline' }}>
          <span className={isPack(r) ? 'd-rnode-pack' : 'd-rnode-leaf'}>{isPack(r) ? r?.title : k}</span>
          <span style={{ flexShrink: 0, fontSize: 12, fontWeight: 600, color: n ? '#ff7a7a' : '#3fc98a' }}>{n ? `${n} ${n === 1 ? 'break' : 'breaks'}` : 'all pass'}</span>
        </span>
        <span className="d-soft" style={{ fontSize: 12, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          {isPack(r) ? `${parents(k).length ? '' : 'root · '}${kids(k).length} sub-rules` : r?.title}
        </span>
      </button>
    )
  }

  return (
    <div className="d-split">
      <aside className="d-picker" style={{ maxWidth: 320, gap: 1 }}>
        <span className="d-caps d-caps-sm" style={{ padding: '0 10px 8px' }}>Rule tree · roots first</span>
        <div className="d-picker-list">
          {tree.map(({ k, depth }, i) => {
            const n = fails(k).length
            const r = byId(k)
            const on = k === id
            const root = depth === 0
            return (
              <button key={`${k}-${i}`} type="button" className={`d-tnode${on ? ' d-pick-on' : ''}`}
                style={{ marginLeft: depth * 16, borderLeft: depth ? '1px solid var(--d-line)' : 0, color: on ? 'var(--d-bright)' : root && applied.has(k) ? 'var(--d-violet)' : 'var(--d-text)' }}
                onClick={() => {
                  if (root && !applied.has(k)) setOpenRoots((s) => new Set([...s, k]))
                  go('rules', `rule:${k}`)
                }}>
                <span className={isPack(r) ? 'd-tnode-pack' : 'd-tnode-leaf'}>{isPack(r) ? r?.title : k}{root && !applied.has(k) ? <span className="d-soft" style={{ fontWeight: 400 }}> · not applied</span> : null}</span>
                <span className={`d-tbadge${n ? ' d-tbadge-bad' : ''}`}>{n ? n : '✓'}</span>
              </button>
            )
          })}
        </div>
      </aside>

      <main className="d-split-main">
        <div className="d-col d-gap-6">
          <nav aria-label="Path from the root" className="d-crumbs">
            <button type="button" className="d-crumb" onClick={() => go('rules')}>{name}</button><span className="d-slash">›</span>
            {path.map((p, i) => (
              <span key={p} className="d-row d-gap-8">
                <button type="button" className="d-crumb" style={{ color: i === path.length - 1 ? 'var(--d-bright)' : undefined, fontWeight: i === 0 ? 700 : 400 }} onClick={() => go('rules', `rule:${p}`)}>
                  {isPack(byId(p)) ? byId(p)?.title : p}
                </button>
                {i < path.length - 1 && <span className="d-slash">›</span>}
              </span>
            ))}
          </nav>
          <div className="d-row" style={{ gap: 14 }}>
            <span style={{ fontFamily: 'var(--d-head)', fontWeight: 700, fontSize: 30, color: 'var(--d-bright)' }}>{rule?.title ?? id}</span>
            <span className={`d-kind d-kind-${kind === 'Root rule' ? 'root' : kind === 'Rule' ? 'leaf' : 'pack'}`}>{kind}</span>
            {link && <span className={`d-held d-held-${howHeld(link, rule)}`}>{howHeld(link, rule) === 'hard' ? 'Hard' : 'Soft'}</span>}
            <button type="button" className="d-ruleref" title="Copy it for the agent" onClick={() => navigator.clipboard.writeText(`@rule:${id}`).catch(() => undefined)}>@rule:{id}</button>
          </div>
          <p className="d-about">{rule?.why}</p>
        </div>

        <section className="d-col d-gap-10">
          <div className="d-row" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
            <span className="d-caps d-caps-sm">How it links · up to its parents, down to its sub-rules</span>
            <span style={{ fontSize: 14, fontWeight: 600, color: mine.length ? '#ff7a7a' : '#3fc98a' }}>
              {mine.length ? `${mine.length} breaks${isPack(rule) ? `, rolled up from ${fromRules} ${fromRules === 1 ? 'rule' : 'rules'} below` : ''}` : 'Everything under it passes'}
            </span>
          </div>
          <div className="d-map-frame">
            <div style={{ position: 'relative', width: dw, height: dh, margin: '0 auto' }}>
              <svg width={dw} height={dh} viewBox={`0 0 ${dw} ${dh}`} style={{ position: 'absolute', left: 0, top: 0 }} aria-hidden="true">
                <path d={upD} fill="none" stroke="#cc66ff" strokeWidth={1.8} opacity={0.85} />
                <path d={failD} fill="none" stroke="#ff7a7a" strokeWidth={1.8} opacity={0.85} />
                <path d={passD} fill="none" stroke="#3fc98a" strokeWidth={1.8} opacity={0.85} />
              </svg>
              <span className="d-map-cap" style={{ left: 24 }}>{up.length ? `Part of · ${up.length}` : 'A root: nothing above it'}</span>
              <span className="d-map-cap" style={{ left: xR }}>{down.length ? `Made of · ${down.length}` : 'Checks the schema directly'}</span>
              {up.map((k, i) => node(k, xL, yL + i * (H + VG)))}
              {down.map((k, i) => node(k, xR, yR + i * (H + VG)))}
              <div className="d-rcenter" style={{ left: xC, top: yC, width: CW, height: CH }}>
                <span className="d-kicker" style={{ display: 'block', padding: '10px 14px 4px' }}>{kind}</span>
                <span className="d-mono" style={{ display: 'block', padding: '0 14px 8px', borderBottom: '1px solid var(--d-input)', fontSize: 15, color: 'var(--d-bright)', overflowWrap: 'anywhere' }}>{id}</span>
                {!up.length && isPack(rule) && (
                  <span className="d-rcrow"><span className="d-soft">On {name}</span><span style={{ color: applied.has(id) ? '#3fc98a' : 'var(--d-gold)', fontWeight: 600 }}>{applied.has(id) ? 'applied' : 'not applied'}</span></span>
                )}
                <span className="d-rcrow"><span className="d-soft">{isPack(rule) ? 'Rules under it' : 'Checks'}</span><span style={{ color: 'var(--d-bright)' }}>{isPack(rule) ? leavesOf(catalog, id).length : checked(id).toLocaleString()}</span></span>
                <span className="d-rcrow"><span className="d-soft">Breaks</span><span style={{ color: mine.length ? '#ff7a7a' : '#3fc98a', fontWeight: 600 }}>{mine.length ? `${mine.length} in ${tablesHit} tables` : 'none'}</span></span>
              </div>
            </div>
          </div>
        </section>

        <section className="d-col d-gap-10">
          <span className="d-caps d-caps-sm">What breaks it · {mine.length ? `${mine.length} in ${tablesHit} tables` : 'none'}</span>
          {!mine.length ? (
            <div style={{ padding: '14px 16px', borderRadius: 12, border: '1px solid #3fc98a', color: '#3fc98a' }}>
              Nothing breaks this rule{isPack(rule) ? ', or any rule under it,' : ''} in {name}.
            </div>
          ) : (
            <div className="d-tbl">
              {mine.slice(0, 60).map((f, i) => (
                <button key={`${f.table}-${f.column}-${f.rule}-${i}`} type="button" className="d-brow"
                  onClick={() => point(f.column ? { kind: 'column', table: f.table, column: f.column } : { kind: 'table', table: f.table })}>
                  <span className="d-mono" style={{ fontSize: 14, color: 'var(--d-bright)', overflowWrap: 'anywhere' }}>@{tname(f.table)}{f.column ? `.${cname(f.column)}` : ''}</span>
                  <span className="d-mono" style={{ fontSize: 13, color: 'var(--d-lilac)' }}>@rule:{f.rule}</span>
                  <span style={{ fontSize: 14, color: '#ff7a7a' }}>{f.message}{f.hard ? ' · hard' : ''}</span>
                </button>
              ))}
              {mine.length > 60 && <div className="d-soft d-small" style={{ padding: '9px 16px', borderTop: '1px solid var(--d-card)' }}>+ {mine.length - 60} more</div>}
            </div>
          )}
        </section>
      </main>
    </div>
  )
}
