// The catalog: every rule by where it applies (every database, one of them, between two) and then by what it is
// about. Pick one to see what it is made of, where it is linked, and what it breaks here or would break if linked.

import { useEffect, useMemo, useState } from 'react'

import { linkRule, preview } from '../api'
import type { Lane, Report, Rule } from '../model'
import { useWorkbench } from '../state'
import { Findings, LANES, MapTable, Strength, TallyBar, mapOf } from './parts'
import { scopeKey, scopeTitle } from './scope'

const TOPICS = ['keys', 'indexes', 'types', 'naming', 'documentation', 'normalization', 'history', 'storage', 'cdc', 'compatibility', 'basics']

export function CatalogView({ selected }: { selected?: string }) {
  const { name, model, ix, go, catalog, rules, reloadRules } = useWorkbench()
  const [lane, setLane] = useState<Lane | ''>('')
  const [query, setQuery] = useState('')
  const [pre, setPre] = useState<Report | null>(null)
  const [locked, setLocked] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const r = catalog.rules.find((x) => x.id === selected)
  const forThis = (x: Rule) => !x.targets?.length || x.targets.includes(model.target)
  const links = [...rules.global, ...rules.links]
  const linksOf = (id: string) => links.filter((l) => l.rule === id && !l.off)
  const reached = (id: string) => !!rules.report.tallies[id]

  const lanes = useMemo(() => {
    const q = query.trim().toLowerCase()
    const hit = (x: Rule) => !q || x.title.toLowerCase().includes(q) || x.id.includes(q)
    return LANES.filter(([l]) => !lane || l === lane).map(([l, label]) => {
      const mine = catalog.rules.filter((x) => x.lane === l)
      const packs = mine.filter((x) => x.rules?.length)
      const topics = TOPICS.map((topic) => {
        const tp = packs.filter((p) => p.topic === topic && (hit(p) || p.rules!.some((c) => hit(catalog.rules.find((y) => y.id === c)!))))
        // Checks of this lane that sit in no pack of this lane: shown on their own, with the pack they come in.
        const loose = mine.filter((x) => !x.rules?.length && x.topic === topic && hit(x) && !packs.some((p) => p.rules!.includes(x.id)))
        return { topic, packs: tp, loose }
      }).filter((t) => t.packs.length || t.loose.length)
      return { lane: l, label, topics }
    }).filter((x) => x.topics.length)
  }, [catalog, lane, query])

  // Not linked here: what it would break if linked to the whole schema.
  useEffect(() => {
    setPre(null)
    setError(null)
    if (r && !reached(r.id) && forThis(r)) preview(name, [{ rule: r.id, at: { level: 'schema' } }]).then(setPre, () => setPre(null))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [r?.id, name, rules])
  const report = pre ?? rules.report
  const tally = (id: string) => report.tallies[id]
  const act = (p: Promise<unknown>) => p.then(() => { setError(null); reloadRules() }, (e) => setError(String(e.message ?? e)))
  const checks = (id: string): string[] => {
    const x = catalog.rules.find((y) => y.id === id)
    return x?.rules?.length ? x.rules.flatMap(checks) : [id]
  }

  const row = (x: Rule, nested = false) => (
    <button key={x.id} type="button" className={`sf-ruleitem${nested ? ' sf-nested-rule' : ''}${x.id === selected ? ' sf-on' : ''}${forThis(x) ? '' : ' sf-dim'}`} onClick={() => go('rules', `catalog:${x.id}`)}>
      <span className="sf-col sf-tight">
        <span className={nested ? '' : 'sf-strong'}>{x.title}</span>
        <span className="sf-mono sf-small sf-muted">@rule:{x.id}{linksOf(x.id).length ? ` · linked at ${linksOf(x.id).length}` : ''}</span>
      </span>
      {forThis(x) ? <TallyBar tally={rules.report.tallies[x.id]} /> : <span className="sf-muted sf-small">not for {model.target}</span>}
    </button>
  )

  return (
    <div className="sf-split sf-split-wide">
      <aside className="sf-catalog">
        <input className="sf-input" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Find a rule" aria-label="Find a rule" />
        <div className="sf-chips">
          {[['', 'All'] as [Lane | '', string], ...LANES].map(([l, label]) => (
            <button key={l} type="button" className={`sf-chip${lane === l ? ' sf-on' : ''}`} onClick={() => setLane(l)}>{label}</button>
          ))}
        </div>
        {lanes.map((l) => (
          <section key={l.lane} className="sf-col">
            <span className="sf-lane">{l.label}</span>
            {l.topics.map((t) => (
              <div key={t.topic} className="sf-col sf-tight">
                <span className="sf-caption">{t.topic}</span>
                {t.packs.map((p) => (
                  <div key={p.id} className="sf-col sf-tight">
                    {row(p)}
                    {p.rules!.map((c) => catalog.rules.find((y) => y.id === c)).filter((c): c is Rule => !!c).map((c) => row(c, true))}
                  </div>
                ))}
                {t.loose.map((x) => row(x))}
              </div>
            ))}
          </section>
        ))}
      </aside>
      <section className="sf-page sf-flex1">
        {!r && (
          <div className="sf-col">
            <span className="sf-title">The catalog</span>
            <p className="sf-about">Rules are sorted first by where they apply: every database (nothing without a key), one of MySQL, PostgreSQL or Iceberg, or between two (compatibility, CDC). Then by what they are about. A pack is a rule made of rules. Pick one to see what it would break in {name}, and link it.</p>
          </div>
        )}
        {r && (
          <>
            <div className="sf-titlerow">
              <span className="sf-caption">{LANES.find(([l]) => l === r.lane)?.[1]} · {r.topic}</span>
            </div>
            <div className="sf-titlerow">
              <span className="sf-title">{r.title}</span>
              <span className="sf-mono sf-ref-inline">@rule:{r.id}</span>
              {!r.rules?.length && <Strength rule={r} />}
            </div>
            <p className="sf-about">{r.why}</p>
            {!forThis(r) && <p className="sf-shared">It checks {r.targets?.join(' and ')} schemas; {name} is {model.target}, so it finds nothing here.</p>}
            <div className="sf-row-between">
              <TallyBar tally={tally(r.id)} preview={!!pre} />
              <span className="sf-row-gap">
                <button type="button" className="sf-chip" onClick={() => go('rules', `rule:${r.id}`)}>Open its diagram</button>
              </span>
            </div>
            {r.rules?.length ? (
              <div className="sf-coltable">
                <div className="sf-rulerow sf-thead"><span>Made of</span><span>Strength</span><span>{pre ? 'If linked to the schema' : `In ${name}`}</span></div>
                {r.rules.map((c) => catalog.rules.find((y) => y.id === c)).filter((c): c is Rule => !!c).map((c) => (
                  <button key={c.id} type="button" className="sf-rulerow" onClick={() => go('rules', `catalog:${c.id}`)}>
                    <span className="sf-col sf-tight"><span className="sf-strong">{c.title}</span><span className="sf-mono sf-small sf-muted">@rule:{c.id}</span></span>
                    <Strength rule={c} />
                    <TallyBar tally={tally(c.id)} preview={!!pre} />
                  </button>
                ))}
              </div>
            ) : null}
            <div className="sf-actions">
              <div className="sf-col">
                <span className="sf-caption">Linked at</span>
                {linksOf(r.id).length === 0 && <span className="sf-muted sf-small">Not linked in {name}.</span>}
                {linksOf(r.id).map((l, i) => (
                  <button key={i} type="button" className="sf-link sf-left" onClick={() => go('rules', `level:${l.at.level === 'global' ? 'schema' : scopeKey(l.at)}`)}>
                    {l.at.level === 'global' ? 'every schema' : scopeTitle(ix, name, l.at)}{l.locked ? ' · locked' : ''}
                  </button>
                ))}
              </div>
              <div className="sf-col">
                <span className="sf-caption">Link it</span>
                <label className="sf-check"><input type="checkbox" checked={locked} onChange={(e) => setLocked(e.target.checked)} /> Locked: cannot be switched off below</label>
                <span className="sf-row-gap">
                  <button type="button" className="sf-button" onClick={() => act(linkRule(name, { rule: r.id, at: { level: 'schema' }, locked: locked || undefined }))}>To the whole of {name}</button>
                  <button type="button" className="sf-chip" onClick={() => act(linkRule(null, { rule: r.id, at: { level: 'global' }, locked: locked || undefined }))}>For every schema</button>
                </span>
                <span className="sf-muted sf-small">For one namespace, family, group or table, open that level in the diagram.</span>
              </div>
              {error && <span className="sf-error" role="alert">{error}</span>}
            </div>
            {mapOf(catalog.maps, r.id) && <section className="sf-col"><span className="sf-caption">The type map it reads</span><MapTable map={mapOf(catalog.maps, r.id)!} /></section>}
            {(() => {
              const set = new Set(checks(r.id))
              const fs = report.findings.filter((f) => set.has(f.rule))
              return fs.length ? <section className="sf-col"><span className="sf-caption">{pre ? 'It would find' : 'What breaks it'} · {fs.length.toLocaleString()}</span><Findings findings={fs} /></section> : null
            })()}
          </>
        )}
      </section>
    </div>
  )
}
