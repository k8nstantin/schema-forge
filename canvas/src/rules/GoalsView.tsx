// Goals: say what the schema has to do (be fed by CDC, run on MySQL and PostgreSQL, move to Iceberg), and see the
// packs it links, what the schema still lacks, and what must be set outside the schema.

import { useEffect, useState } from 'react'

import { applyGoal, preview } from '../api'
import type { Report, Target } from '../model'
import { useWorkbench } from '../state'
import { Findings, TallyBar } from './parts'

const NAMES: Record<Target, string> = { mysql: 'MySQL', postgres: 'PostgreSQL', iceberg: 'Iceberg' }

export function GoalsView({ selected }: { selected?: string }) {
  const { name, model, go, catalog, rules, reloadRules } = useWorkbench()
  const [gap, setGap] = useState<Report | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const g = catalog.goals.find((x) => x.id === selected) ?? catalog.goals[0]
  const packs = g?.packs.find(([t]) => t === model.target)?.[1] ?? []
  const linked = (p: string) => rules.links.some((l) => l.rule === p && l.at.level === 'schema' && !l.off) || rules.global.some((l) => l.rule === p)
  const missing = packs.filter((p) => !linked(p))

  useEffect(() => {
    setGap(null)
    setError(null)
    if (packs.length) preview(name, missing.map((rule) => ({ rule, at: { level: 'schema' } }))).then(setGap, (e) => setError(String(e.message ?? e)))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [g?.id, name, rules])
  if (!g) return null
  const checks = (id: string): string[] => {
    const x = catalog.rules.find((y) => y.id === id)
    return x?.rules?.length ? x.rules.flatMap(checks) : [id]
  }
  const goalChecks = [...new Set(packs.flatMap(checks))].filter((c) => {
    const r = catalog.rules.find((x) => x.id === c)
    return !r?.targets?.length || r.targets.includes(model.target)
  })
  const prompt = `Make ${name} ready to ${g.title.toLowerCase()} under @goal:${g.id}: fix what its packs find, and ask me where there is a choice.`
  return (
    <div className="sf-split sf-split-wide">
      <aside className="sf-catalog">
        {catalog.goals.map((x) => {
          const fits = x.packs.some(([t]) => t === model.target)
          return (
            <button key={x.id} type="button" className={`sf-goal${x.id === g.id ? ' sf-on' : ''}${fits ? '' : ' sf-dim'}`} onClick={() => go('rules', `goals:${x.id}`)}>
              <span className="sf-famname">{x.title}</span>
              <span className="sf-muted sf-small">{x.about}</span>
              {!fits && <span className="sf-muted sf-small">For a {x.packs.map(([t]) => NAMES[t]).join(' or ')} schema</span>}
            </button>
          )
        })}
      </aside>
      <section className="sf-page sf-flex1">
        <span className="sf-caption">goal</span>
        <span className="sf-title">{g.title}</span>
        <p className="sf-about">{g.about}</p>
        {!packs.length && <p className="sf-shared">This goal is for a {g.packs.map(([t]) => NAMES[t]).join(' or ')} schema; {name} is {NAMES[model.target]}.</p>}
        {packs.length > 0 && (
          <>
            <div className="sf-col">
              <span className="sf-caption">It links these packs to the whole schema</span>
              <div className="sf-chips">
                {packs.map((p) => (
                  <button key={p} type="button" className={`sf-chip${linked(p) ? ' sf-on' : ''}`} onClick={() => go('rules', `catalog:${p}`)}>
                    {catalog.rules.find((r) => r.id === p)?.title}{linked(p) ? ' · linked' : ''}
                  </button>
                ))}
              </div>
            </div>
            <div className="sf-coltable">
              <div className="sf-rulerow sf-thead"><span>{name} needs</span><span>Strength</span><span>Now</span></div>
              {goalChecks.map((c) => {
                const r = catalog.rules.find((x) => x.id === c)!
                return (
                  <button key={c} type="button" className="sf-rulerow" onClick={() => go('rules', `catalog:${c}`)}>
                    <span className="sf-col sf-tight"><span className="sf-strong">{r.title}</span><span className="sf-muted sf-small">{r.why}</span></span>
                    <span className={`sf-strength sf-${r.strength}`}>{r.strength === 'must' ? 'Must' : 'Should'}</span>
                    <TallyBar tally={(gap ?? rules.report).tallies[c]} />
                  </button>
                )
              })}
            </div>
            <span className="sf-row-gap">
              <button type="button" className="sf-button" disabled={!missing.length}
                onClick={() => applyGoal(name, g.id).then(() => { setError(null); reloadRules() }, (e) => setError(String(e.message ?? e)))}>
                {missing.length ? `Link the ${missing.length === 1 ? 'pack' : `${missing.length} packs`}` : 'All its packs are linked'}
              </button>
              <button type="button" className="sf-chip" onClick={() => navigator.clipboard.writeText(prompt).then(() => setCopied(true), () => setCopied(false))}>{copied ? 'Copied' : 'Copy for the agent'}</button>
            </span>
            <span className="sf-mono sf-small sf-muted">{prompt}</span>
            {error && <span className="sf-error" role="alert">{error}</span>}
          </>
        )}
        {g.outside.length > 0 && (
          <div className="sf-col sf-outside">
            <span className="sf-strong">Outside the schema</span>
            <span className="sf-muted sf-small">Schema Forge cannot check these: they are set on the database itself.</span>
            {g.outside.map(([t, items]) => (
              <div key={t} className="sf-col sf-tight">
                <span className="sf-caption">On {NAMES[t]}</span>
                {items.map(([k, v]) => <span key={k}><span className="sf-mono sf-type">{k}</span> <span className="sf-muted">{v}</span></span>)}
              </div>
            ))}
          </div>
        )}
        {gap && gap.findings.length > 0 && (
          <section className="sf-col">
            <span className="sf-caption">What is missing · {gap.findings.length.toLocaleString()}</span>
            <Findings findings={gap.findings.filter((f) => goalChecks.includes(f.rule))} />
          </section>
        )}
      </section>
    </div>
  )
}
