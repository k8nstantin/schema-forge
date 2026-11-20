// What breaks what: hover a rule and the tables that break it light up (red if it is hard, amber if soft); hover a
// table and the rules it breaks light up, with what is wrong. Click to keep it. Each linked rule can be set hard or
// soft right here.

import { useMemo, useState } from 'react'

import { setEnforce } from '../api'
import type { Enforce, RuleLink } from '../model'
import { useWorkbench } from '../state'
import { EnforceToggle, Findings } from './parts'
import { scopeTitle } from './scope'

type Focus = { kind: 'rule' | 'table'; id: string } | null

export function BreaksView() {
  const { name, ix, catalog, rules, reloadRules } = useWorkbench()
  const [hover, setHover] = useState<Focus>(null)
  const [pin, setPin] = useState<Focus>(null)
  const [show, setShow] = useState<'all' | 'hard' | 'soft'>('all')
  const [error, setError] = useState<string | null>(null)
  const focus = hover ?? pin
  const title = (id: string) => catalog.rules.find((r) => r.id === id)?.title ?? id
  const checksOf = (id: string): string[] => {
    const r = catalog.rules.find((x) => x.id === id)
    return r?.rules?.length ? r.rules.flatMap(checksOf) : [id]
  }
  // The linked rules (not exceptions), each with its links, its checks and the tables breaking it, hard or soft.
  const linked = useMemo(() => {
    const byRule = new Map<string, { link: RuleLink; global: boolean }[]>()
    for (const [l, global] of [...rules.global.map((l) => [l, true] as const), ...rules.links.map((l) => [l, false] as const)]) {
      if (l.off) continue
      if (!byRule.has(l.rule)) byRule.set(l.rule, [])
      byRule.get(l.rule)!.push({ link: l, global })
    }
    return [...byRule].map(([id, links]) => {
      const checks = new Set(checksOf(id))
      const fs = rules.report.findings.filter((f) => checks.has(f.rule))
      const tables = new Map<string, { hard: boolean }>()
      for (const f of fs) tables.set(f.table, { hard: (tables.get(f.table)?.hard ?? false) || f.hard })
      const hard = fs.some((f) => f.hard)
      const mode: Enforce | undefined = links.every((l) => l.link.enforce === 'hard') ? 'hard' : links.every((l) => l.link.enforce === 'soft') ? 'soft' : undefined
      return { id, links, checks, findings: fs, tables, hard, mode }
    }).sort((a, b) => b.tables.size - a.tables.size)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rules, catalog])
  const visible = linked.filter((r) => show === 'all' || (show === 'hard' ? r.hard || r.mode === 'hard' : !r.hard))
  const visibleFindings = rules.report.findings.filter((f) => visible.some((r) => r.checks.has(f.rule)))
  const byTable = new Map<string, { hard: boolean; n: number }>()
  for (const f of visibleFindings) {
    const t = byTable.get(f.table) ?? { hard: false, n: 0 }
    byTable.set(f.table, { hard: t.hard || f.hard, n: t.n + 1 })
  }
  const litRule = focus?.kind === 'rule' ? linked.find((r) => r.id === focus.id) : undefined
  const litTable = focus?.kind === 'table' ? focus.id : undefined
  const set = (r: (typeof linked)[number], e: Enforce) =>
    Promise.all(r.links.map(({ link, global }) => setEnforce(global ? null : name, link.rule, link.at, e))).then(() => { setError(null); reloadRules() }, (err) => setError(String(err.message ?? err)))
  const families = [...ix.families.values()]
  const tableFindings = litTable ? visibleFindings.filter((f) => f.table === litTable) : []
  return (
    <div className="sf-page">
      <div className="sf-row-between">
        <span className="sf-muted">Hover a rule: the tables that break it light up. Hover a table: the rules it breaks. Click to keep it.</span>
        <span className="sf-enforce" role="group" aria-label="Show">
          {(['all', 'hard', 'soft'] as const).map((k) => (
            <button key={k} type="button" className={show === k ? 'sf-on-plain' : ''} onClick={() => setShow(k)}>{k === 'all' ? 'All rules' : k === 'hard' ? 'Hard only' : 'Soft only'}</button>
          ))}
        </span>
      </div>
      <div className="sf-legend">
        <span><span className="sf-swatch sf-hard" />hard: enforced, the agent's change is refused</span>
        <span><span className="sf-swatch sf-soft" />soft: highlighted only</span>
        <span><span className="sf-swatch sf-passing" />passes</span>
      </div>
      {error && <span className="sf-error" role="alert">{error}</span>}
      <div className="sf-breakgrid">
        <section className="sf-breakrules" aria-label="Rules">
          {visible.length === 0 && <span className="sf-muted">No rules are linked. Link them in the Diagram, or review the agent's.</span>}
          {visible.map((r) => {
            const lit = litRule?.id === r.id || (litTable && r.tables.has(litTable))
            const dim = (litRule && litRule.id !== r.id) || (litTable && !r.tables.has(litTable))
            return (
              <div key={r.id} className={`sf-breakrule${lit ? (r.tables.size ? (r.hard ? ' sf-lit-hard' : ' sf-lit-soft') : ' sf-lit-pass') : ''}${dim ? ' sf-dim' : ''}`}
                onMouseEnter={() => setHover({ kind: 'rule', id: r.id })} onMouseLeave={() => setHover(null)}>
                <button type="button" className="sf-breakrule-name" onClick={() => setPin(pin?.id === r.id ? null : { kind: 'rule', id: r.id })}>
                  <span className="sf-strong">{title(r.id)}</span>
                  <span className="sf-muted sf-small">
                    {r.links.map((l) => (l.global ? 'every schema' : scopeTitle(ix, name, l.link.at))).join(', ')} · {r.tables.size ? `${r.tables.size} ${r.tables.size === 1 ? 'table breaks' : 'tables break'} it` : 'every table passes'}
                  </span>
                </button>
                <EnforceToggle value={r.mode} onChange={(e) => set(r, e)} fallback="defaults" />
              </div>
            )
          })}
        </section>
        <section className="sf-col sf-flex1" aria-label="Tables">
          <div className={`sf-breakpanel${litRule ? (litRule.hard ? ' sf-lit-hard' : ' sf-lit-soft') : litTable ? ' sf-lit-table' : ''}`}>
            {litRule && (
              <>
                <span className="sf-caption">rule · {litRule.hard ? 'hard: enforced' : 'soft: highlighted only'}</span>
                <span className="sf-strong">{title(litRule.id)}: {litRule.tables.size ? `${litRule.tables.size} ${litRule.tables.size === 1 ? 'table breaks' : 'tables break'} it` : 'every table passes'}</span>
                <Findings findings={litRule.findings} limit={4} />
              </>
            )}
            {litTable && (
              <>
                <span className="sf-caption">table · {ix.familyOf(litTable) ? `${ix.path(ix.familyOf(litTable)!.namespace)} › ${ix.familyOf(litTable)!.name}` : ''}</span>
                <span className="sf-strong">{ix.tables.get(litTable)?.name}: {tableFindings.length ? `breaks ${new Set(tableFindings.map((f) => f.rule)).size} rules` : 'passes every rule'}</span>
                <Findings findings={tableFindings} limit={6} />
              </>
            )}
            {!focus && <span className="sf-muted">{byTable.size} of {ix.tables.size} tables break a rule shown · {[...byTable.values()].filter((t) => t.hard).length} a hard one</span>}
          </div>
          {families.map((f) => (
            <div key={f.key} className="sf-col sf-tight">
              <span className="sf-row-gap"><span className="sf-ns">{ix.path(f.namespace)}</span><span className="sf-muted sf-small">› {f.name}</span></span>
              <div className="sf-tiles">
                {f.tables.map((t) => {
                  const b = byTable.get(t.id)
                  let cls = b ? (b.hard ? 'sf-tile sf-tile-hard' : 'sf-tile sf-tile-soft') : 'sf-tile sf-tile-pass'
                  if (litRule) cls = litRule.tables.has(t.id) ? `sf-tile ${litRule.tables.get(t.id)!.hard ? 'sf-tile-lit-hard' : 'sf-tile-lit-soft'}` : 'sf-tile sf-tile-dim'
                  else if (litTable) cls = litTable === t.id ? 'sf-tile sf-tile-lit' : 'sf-tile sf-tile-dim'
                  return (
                    <button key={t.id} type="button" className={cls} onMouseEnter={() => setHover({ kind: 'table', id: t.id })} onMouseLeave={() => setHover(null)}
                      onClick={() => setPin(pin?.id === t.id ? null : { kind: 'table', id: t.id })}>
                      {t.name}{b && !litRule && !litTable ? <span className={`sf-tilecount ${b.hard ? 'sf-hard' : 'sf-soft'}`}>{b.n}</span> : null}
                    </button>
                  )
                })}
              </div>
            </div>
          ))}
        </section>
      </div>
    </div>
  )
}
