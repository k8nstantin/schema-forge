// The rules as link diagrams. A level: the rules that reach it on the left, the level and what is inside it in the
// middle, the exceptions on the right. A rule: the packs it sits in on the left, the rule and the rules it is made
// of in the middle, where it is linked and switched off on the right.

import { useMemo, useState } from 'react'

import { linkRule, setEnforce, unlinkRule } from '../api'
import { LinkDiagram, type Card, type Line, type Row } from '../diagram/LinkDiagram'
import type { Applied, Enforce, RuleLink, Scope, Table } from '../model'
import { useWorkbench } from '../state'
import { EnforceToggle, Findings, LANES, MapTable, Strength, TallyBar, mapOf } from './parts'
import { ALL } from './parts'
import { childrenOf, holds, levelName, path, sameScope, scopeKey, scopeTitle } from './scope'

const MAX_ROWS = 40

export function LevelDiagram({ scope }: { scope: Scope }) {
  const { name, model, ix, go, catalog, rules } = useWorkbench()
  const groups = rules.groups
  const all = model.tables ?? []
  const under = useMemo(() => all.filter((t) => holds(ix, groups, scope, t)), [all, ix, groups, scope])
  const children = useMemo(() => childrenOf(ix, all, groups, name, scope), [ix, all, groups, name, scope])
  const shown = children.slice(0, MAX_ROWS)
  const rule = (id: string) => (id === ALL ? { id, title: 'All rules', strength: 'should', rules: ['*'] } : catalog.rules.find((r) => r.id === id))

  // Where a rule reaches from: the whole level (the header), or the rows inside it its tables are in.
  const landing = (from: Scope, tables: Set<string>): string[] => {
    if (under.every((t) => holds(ix, groups, from, t))) return ['@']
    const exact = shown.find((c) => sameScope(c.scope, from))
    if (exact) return [scopeKey(exact.scope)]
    return shown.filter((c) => c.tables.some((t) => tables.has(t.id))).map((c) => scopeKey(c.scope))
  }

  const { left, right, lines } = useMemo(() => {
    const reach = new Map<string, { a: Applied; tables: Set<string> }>()
    const off = new Map<string, { rule: string; at: Scope; reason: string; tables: Set<string> }>()
    for (const t of under) {
      const eff = rules.report.tables[t.id]
      for (const a of eff?.applied ?? []) {
        const k = `${a.rule}|${scopeKey(a.from)}`
        if (!reach.has(k)) reach.set(k, { a, tables: new Set() })
        reach.get(k)!.tables.add(t.id)
      }
      for (const e of eff?.excepted ?? []) {
        const k = `${e.rule}|${scopeKey(e.at)}`
        if (!off.has(k)) off.set(k, { ...e, tables: new Set() })
        off.get(k)!.tables.add(t.id)
      }
    }
    const byRule = new Map<string, { a: Applied; tables: Set<string> }[]>()
    for (const r of reach.values()) {
      if (!byRule.has(r.a.rule)) byRule.set(r.a.rule, [])
      byRule.get(r.a.rule)!.push(r)
    }
    const lines: Line[] = []
    const left: Card[] = [...byRule].map(([id, rs]) => {
      const r = rule(id)
      const froms = rs.map((x) => x.a.from)
      const sub = froms.length > 1
        ? `linked at ${froms.length} levels`
        : sameScope(froms[0], scope)
          ? `linked here${rs[0].a.locked ? ' · locked' : ''}`
          : under.every((t) => holds(ix, groups, froms[0], t))
            ? `from ${froms[0].level === 'global' ? 'every schema' : `${levelName(froms[0])} ${scopeTitle(ix, name, froms[0])}`}${rs[0].a.locked ? ' · locked' : ''}`
            : `linked at ${scopeTitle(ix, name, froms[0])}`
      for (const x of rs) {
        const above = !sameScope(x.a.from, scope) && under.every((t) => holds(ix, groups, x.a.from, t))
        for (const row of landing(x.a.from, x.tables)) lines.push({ side: 'left', card: id, row: row === '@' ? undefined : row, tone: above ? 'above' : undefined })
      }
      return { key: id, title: r?.title ?? id, meta: strengthNote(r), sub, color: r?.strength === 'must' ? '#f5c26b' : '#cc66ff', onClick: () => go('rules', `rule:${id}`) }
    })
    const right: Card[] = [...off.entries()].map(([k, e]) => {
      for (const row of landing(e.at, e.tables)) lines.push({ side: 'right', card: k, row: row === '@' ? undefined : row, tone: 'off' })
      return { key: k, title: `− ${rule(e.rule)?.title ?? e.rule}`, meta: e.rule === ALL ? 'no rules here' : rule(e.rule)?.rules?.length ? 'whole rule' : 'one rule', sub: `at ${scopeTitle(ix, name, e.at)}: ${e.reason}`, tone: 'off' as const, onClick: () => go('rules', `level:${scopeKey(e.at)}`) }
    })
    return { left, right, lines }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [under, rules, shown, scope])

  const joined = new Set(lines.map((l) => l.row).filter(Boolean))
  const rows: Row[] = shown.map((c) => ({
    key: scopeKey(c.scope),
    name: `${c.caption === 'namespace' ? '' : ''}${c.title}`,
    note: c.scope.level === 'table' ? c.caption : `${c.caption} · ${c.tables.length}`,
    joins: joined.has(scopeKey(c.scope)),
    onClick: () => go('rules', `level:${scopeKey(c.scope)}`),
  }))
  const findings = rules.report.findings.filter((f) => under.some((t) => t.id === f.table))
  const none = [...rules.global, ...rules.links].find((l) => l.rule === ALL && sameScope(l.at, scope))

  return (
    <div className="sf-col sf-gap-l">
      <Crumbs scope={scope} />
      <div className="sf-titlerow">
        <span className="sf-caption">{levelName(scope)}</span>
        <span className={scope.level === 'schema' || scope.level === 'namespace' ? 'sf-ns sf-ns-big' : 'sf-title'}>{scopeTitle(ix, name, scope)}</span>
        <span className="sf-muted">{under.length.toLocaleString()} {under.length === 1 ? 'table' : 'tables'} · {left.length} rules reach it · {right.length} {right.length === 1 ? 'exception' : 'exceptions'}</span>
      </div>
      {none && <p className="sf-shared">No rules here: {none.reason}. Rules linked further down still apply.</p>}
      <Legend />
      <LinkDiagram
        leftHead={`Rules that reach it · ${left.length}`}
        rightHead={`Switched off · ${right.length}`}
        left={left}
        right={right}
        lines={lines}
        center={{ caption: levelName(scope), title: scopeTitle(ix, name, scope), color: '#cc66ff', rows }}
        empty="No rules reach it yet: link one below, or start from a goal."
      />
      {children.length > MAX_ROWS && <span className="sf-muted sf-small">Showing {MAX_ROWS} of {children.length} inside it.</span>}
      <LevelActions scope={scope} under={under} />
      {findings.length > 0 && (
        <section className="sf-col">
          <span className="sf-caption">What breaks here · {findings.length.toLocaleString()}</span>
          <Findings findings={findings} />
        </section>
      )}
    </div>
  )
}

function Legend() {
  return (
    <div className="sf-legend">
      <span><svg width="34" height="10" aria-hidden="true"><path d="M2 5 H32" className="sf-line sf-above" /></svg>reaches it from a wider level</span>
      <span><svg width="34" height="10" aria-hidden="true"><path d="M2 5 H32" className="sf-line" /></svg>linked here, or inside it (gold rows)</span>
      <span><svg width="34" height="10" aria-hidden="true"><path d="M2 5 H32" className="sf-line sf-off" /></svg>switched off, with a reason</span>
    </div>
  )
}

function Crumbs({ scope }: { scope: Scope }) {
  const { name, ix, go } = useWorkbench()
  const steps = path(ix, scope)
  return (
    <nav className="sf-crumbs" aria-label="Where this level is">
      {steps.map((s, i) => (
        <span key={scopeKey(s)} className="sf-crumb">
          {i > 0 && <span>›</span>}
          {i === steps.length - 1
            ? <span className="sf-strong">{scopeTitle(ix, name, s)}</span>
            : <button type="button" className={s.level === 'namespace' ? 'sf-nspill' : 'sf-link'} onClick={() => go('rules', `level:${scopeKey(s)}`)}>{scopeTitle(ix, name, s)}</button>}
        </span>
      ))}
    </nav>
  )
}

/// Link a rule here, switch one off here, take away what is linked here.
function LevelActions({ scope, under }: { scope: Scope; under: Table[] }) {
  const { name, ix, catalog, rules, reloadRules } = useWorkbench()
  const [pick, setPick] = useState('')
  const [locked, setLocked] = useState(false)
  const [enforce, setHow] = useState<Enforce | undefined>(undefined)
  const [everywhere, setEverywhere] = useState(false)
  const [offPick, setOffPick] = useState('')
  const [reason, setReason] = useState('')
  const [error, setError] = useState<string | null>(null)
  const title = (id: string) => (id === ALL ? 'All rules: none here' : catalog.rules.find((r) => r.id === id)?.title ?? id)
  const here: { link: RuleLink; global: boolean }[] = [
    ...(scope.level === 'schema' ? rules.global.map((link) => ({ link, global: true })) : []),
    ...rules.links.filter((l) => sameScope(l.at, scope)).map((link) => ({ link, global: false })),
  ]
  // What can be switched off here: every rule reaching all of it from a wider level, and the rules inside those.
  const reaching = [...new Set(under.flatMap((t) => (rules.report.tables[t.id]?.applied ?? []).filter((a) => !sameScope(a.from, scope)).map((a) => a.rule)))]
  const offable = [...new Set(reaching.flatMap((r) => [r, ...inside(r)]))]
  function inside(id: string): string[] {
    const r = catalog.rules.find((x) => x.id === id)
    return (r?.rules ?? []).flatMap((c) => [c, ...inside(c)])
  }
  const act = (p: Promise<unknown>) => p.then(() => { setError(null); reloadRules() }, (e) => setError(String(e.message ?? e)))
  return (
    <section className="sf-actions">
      <div className="sf-col">
        <span className="sf-caption">Linked at {scopeTitle(ix, name, scope)}</span>
        {here.length === 0 && <span className="sf-muted sf-small">Nothing is linked at this level itself.</span>}
        {here.map(({ link, global }) => (
          <div key={`${global}${link.rule}`} className="sf-row-between sf-linkrow">
            <span>
              <span className={link.off ? 'sf-struck' : 'sf-strong'}>{link.off ? '− ' : ''}{title(link.rule)}</span>
              <span className="sf-muted sf-small"> {global ? 'for every schema' : ''}{link.locked ? ' · locked' : ''}{link.off ? ` · ${link.reason}` : ''}</span>
            </span>
            <span className="sf-row-gap">
              {!link.off && link.rule !== ALL && <EnforceToggle value={link.enforce} fallback="defaults" onChange={(e) => act(setEnforce(global ? null : name, link.rule, link.at, e))} />}
              <button type="button" className="sf-chip" onClick={() => act(unlinkRule(global ? null : name, link.rule, link.at))}>Take away</button>
            </span>
          </div>
        ))}
      </div>
      <div className="sf-col">
        <span className="sf-caption">Link a rule here</span>
        <select className="sf-input" value={pick} onChange={(e) => setPick(e.target.value)} aria-label="The rule to link">
          <option value="">Choose a rule or a pack…</option>
          {LANES.map(([lane, label]) => (
            <optgroup key={lane} label={label}>
              {catalog.rules.filter((r) => r.lane === lane).sort((a, b) => Number(!a.rules?.length) - Number(!b.rules?.length) || a.topic.localeCompare(b.topic)).map((r) => (
                <option key={r.id} value={r.id}>{r.rules?.length ? `${r.title} (pack)` : `   ${r.title}`}</option>
              ))}
            </optgroup>
          ))}
        </select>
        <span className="sf-row-gap"><EnforceToggle value={enforce} onChange={setHow} fallback="choose how it holds" /></span>
        <label className="sf-check"><input type="checkbox" checked={locked} onChange={(e) => setLocked(e.target.checked)} /> Locked: cannot be switched off below</label>
        {scope.level === 'schema' && <label className="sf-check"><input type="checkbox" checked={everywhere} onChange={(e) => setEverywhere(e.target.checked)} /> For every schema of the workspace</label>}
        <button type="button" className="sf-button" disabled={!pick || !enforce}
          onClick={() => act(linkRule(everywhere ? null : name, { rule: pick, at: everywhere ? { level: 'global' } : scope, locked: locked || undefined, enforce }).then(() => setPick('')))}>
          Link
        </button>
      </div>
      <div className="sf-col">
        <span className="sf-caption">Switch a rule off here</span>
        <select className="sf-input" value={offPick} onChange={(e) => setOffPick(e.target.value)} aria-label="The rule to switch off">
          <option value="">Choose what to switch off…</option>
          <option value={ALL}>No rules here at all</option>
          {offable.map((r) => <option key={r} value={r}>{title(r)}</option>)}
        </select>
        <input className="sf-input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Why: the agent reads it too" aria-label="Why it is switched off" />
        <button type="button" className="sf-button" disabled={!offPick || !reason.trim()}
          onClick={() => act(linkRule(name, { rule: offPick, at: scope, off: true, reason }).then(() => { setOffPick(''); setReason('') }))}>
          Switch off
        </button>
      </div>
      {error && <span className="sf-error" role="alert">{error}</span>}
    </section>
  )
}

/// A check's strength, or how many rules a pack holds.
function strengthNote(r?: { strength: string; rules?: string[] }): string {
  if (!r) return ''
  if (r.rules?.length) return `${r.rules.length} ${r.rules.length === 1 ? 'rule' : 'rules'}`
  return r.strength === 'must' ? 'Must' : 'Should'
}

export function RuleDiagram({ id }: { id: string }) {
  const { name, ix, go, catalog, rules } = useWorkbench()
  const r = catalog.rules.find((x) => x.id === id)
  if (!r) return <span className="sf-muted">There is no rule `{id}`.</span>
  const parents = catalog.rules.filter((p) => p.rules?.includes(id))
  const inside = (outer: string, inner: string): boolean => outer === inner || (catalog.rules.find((x) => x.id === outer)?.rules ?? []).some((c) => inside(c, inner))
  const all = [...rules.global.map((l) => ({ l, global: true })), ...rules.links.map((l) => ({ l, global: false }))]
  // Its own links and exceptions, those on rules inside it, and links of packs it sits in that bring it along.
  const mine = all.filter(({ l }) => inside(id, l.rule) || (!l.off && inside(l.rule, id) && l.rule !== id))
  const left: Card[] = parents.map((p) => ({ key: p.id, title: p.title, meta: strengthNote(p), sub: `holds ${r.title}`, onClick: () => go('rules', `rule:${p.id}`) }))
  const lines: Line[] = left.map((c) => ({ side: 'left', card: c.key }))
  const rows: Row[] = (r.rules ?? []).map((c) => {
    const cr = catalog.rules.find((x) => x.id === c)
    const t = rules.report.tallies[c]
    return { key: c, name: cr?.title ?? c, note: t ? (t.breaks ? `${t.breaks} break` : 'pass') : cr?.rules?.length ? 'pack' : '', joins: !!t?.breaks, onClick: () => go('rules', `rule:${c}`) }
  })
  const right: Card[] = mine.map(({ l, global }, i) => {
    const key = `${i}`
    const row = l.rule === id || !l.off ? undefined : (r.rules ?? []).find((c) => inside(c, l.rule))
    lines.push({ side: 'right', card: key, row, tone: l.off ? 'off' : l.rule === id ? undefined : 'above' })
    const where = global ? 'every schema' : scopeTitle(ix, name, l.at)
    return {
      key,
      title: l.off ? `− at ${where}` : where,
      meta: l.off ? (l.rule === id ? 'whole rule' : 'one rule') : l.rule === id ? (l.locked ? 'linked · locked' : 'linked') : 'through',
      sub: l.off ? l.reason : l.rule === id ? levelName(l.at) : `with ${catalog.rules.find((x) => x.id === l.rule)?.title}`,
      tone: l.off ? ('off' as const) : undefined,
      onClick: () => go('rules', global ? 'level:schema' : `level:${scopeKey(l.at)}`),
    }
  })
  const checks = new Set<string>()
  const walk = (x: string) => { const rr = catalog.rules.find((y) => y.id === x); if (!rr?.rules?.length) checks.add(x); rr?.rules?.forEach(walk) }
  walk(id)
  const findings = rules.report.findings.filter((f) => checks.has(f.rule))
  const map = mapOf(catalog.maps, id)
  return (
    <div className="sf-col sf-gap-l">
      <nav className="sf-crumbs"><button type="button" className="sf-link" onClick={() => go('rules', 'level:schema')}>{name}</button><span>›</span><span className="sf-strong">{r.title}</span></nav>
      <div className="sf-titlerow">
        <span className="sf-caption">{parents.length ? 'rule' : 'root rule'}</span>
        <span className="sf-title">{r.title}</span>
        <span className="sf-mono sf-ref-inline">@rule:{r.id}</span>
        {!r.rules?.length && <Strength rule={r} />}
        <TallyBar tally={rules.report.tallies[id]} />
      </div>
      <p className="sf-about">{r.why}{r.targets?.length ? ` Checks ${r.targets.join(' and ')} schemas.` : ''}</p>
      <Legend />
      <LinkDiagram
        leftHead={parents.length ? `Part of · ${parents.length}` : 'Part of · none: a root rule'}
        rightHead={`Linked at, and switched off · ${right.length}`}
        left={left}
        right={right}
        lines={lines}
        center={{ caption: r.rules?.length ? `made of ${r.rules.length}` : 'a check', title: r.title, color: r.strength === 'must' ? '#f5c26b' : '#cc66ff', rows }}
        empty="Not linked anywhere in this schema: link it from a level, or from Rules."
      />
      {map && <section className="sf-col"><span className="sf-caption">The type map it reads: {map.from} → {map.to}</span><MapTable map={map} /></section>}
      {findings.length > 0 && (
        <section className="sf-col">
          <span className="sf-caption">What breaks it · {findings.length.toLocaleString()}</span>
          <Findings findings={findings} />
        </section>
      )}
    </div>
  )
}
