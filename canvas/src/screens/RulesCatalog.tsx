// Rules, as the "3 · Rules" board draws it: every pack, by where it applies, to find and open; the open pack with
// what it is, what it holds, how each rule holds by default, and the schemas that use it.

import { useEffect, useMemo, useState } from 'react'

import { schemaRules, schemas as fetchSchemas } from '../api'
import type { Catalog, Rule } from '../model'
import { LANES, holdsRule } from '../rules/parts'
import { Brand, count } from './parts'

function checksOf(cat: Catalog, id: string, seen = new Set<string>()): Rule[] {
  if (seen.has(id)) return []
  seen.add(id)
  const r = cat.rules.find((x) => x.id === id)
  if (!r) return []
  return r.rules?.length ? r.rules.flatMap((k) => checksOf(cat, k, seen)) : [r]
}

export function RulesCatalog({ catalog }: { catalog: Catalog | null }) {
  const [query, setQuery] = useState('')
  const [picked, setPicked] = useState<string | null>(null)
  const [usedBy, setUsedBy] = useState<Map<string, string[]>>(new Map())

  const packs = useMemo(() => (catalog?.rules ?? []).filter((r) => r.rules?.length), [catalog])
  // Which schemas use each pack: linked to it, or to a pack that holds it, here or for every schema.
  useEffect(() => {
    if (!catalog) return
    fetchSchemas()
      .then((infos) => Promise.all(infos.map(async (i) => ({ name: i.name, rules: await schemaRules(i.name).catch(() => null) }))))
      .then((all) => {
        const m = new Map<string, string[]>()
        for (const p of packs) {
          m.set(p.id, all.filter(({ rules }) => [...(rules?.global ?? []), ...(rules?.links ?? [])].some((l) => !l.off && holdsRule(catalog, l.rule, p.id))).map((x) => x.name))
        }
        setUsedBy(m)
      }, () => setUsedBy(new Map()))
  }, [catalog, packs])

  const q = query.trim().toLowerCase()
  const hit = (p: Rule) => !q || p.title.toLowerCase().includes(q) || p.id.includes(q) || (catalog ? checksOf(catalog, p.id).some((c) => c.title.toLowerCase().includes(q) || c.id.includes(q)) : false)
  const pack = packs.find((p) => p.id === picked) ?? packs.find(hit) ?? packs[0]
  const laneOf = (p: Rule) => LANES.find(([l]) => l === p.lane)?.[1] ?? p.lane
  const rules = pack && catalog ? checksOf(catalog, pack.id) : []
  const users = pack ? usedBy.get(pack.id) ?? [] : []

  return (
    <div className="d-page">
      <header className="d-bar">
        <div className="d-row" style={{ gap: 16 }}>
          <Brand />
          <span className="d-slash">/</span>
          <span style={{ fontWeight: 600, fontSize: 16 }}>Rules</span>
        </div>
        <span className="d-soft d-small">The agent proposes new rules in a schema's Rules; you approve them there.</span>
      </header>

      <div className="d-row" style={{ alignItems: 'stretch', flex: 1, gap: 0, flexWrap: 'wrap' }}>
        <aside className="d-rc-side">
          <label className="d-col d-gap-6">
            <span className="d-small d-soft">Find a pack or rule</span>
            <input className="d-find" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="keys, history, iceberg…" />
          </label>
          {LANES.map(([lane, label]) => {
            const mine = packs.filter((p) => p.lane === lane && hit(p))
            if (!mine.length) return null
            return (
              <div key={lane} className="d-col d-gap-6">
                <span className="d-caps d-caps-sm" style={{ padding: '0 8px' }}>{label}</span>
                {mine.map((p) => (
                  <button key={p.id} type="button" aria-pressed={pack?.id === p.id} onClick={() => setPicked(p.id)}
                    className={`d-rc-pack${pack?.id === p.id ? ' d-rc-pack-on' : ''}`}>
                    <span style={{ fontWeight: 600 }}>{p.title}</span>
                    <span className="d-xsmall d-soft">{count(catalog ? checksOf(catalog, p.id).length : 0, 'rule')} · {laneOf(p)}</span>
                  </button>
                ))}
              </div>
            )
          })}
        </aside>

        {pack && (
          <main className="d-rc-main">
            <div className="d-row" style={{ justifyContent: 'space-between', alignItems: 'flex-start', gap: 16 }}>
              <div className="d-col d-gap-6" style={{ maxWidth: 720 }}>
                <h1 className="d-h1" style={{ fontSize: 32 }}>{pack.title}</h1>
                <p className="d-soft" style={{ margin: 0, fontSize: 16 }}>{pack.why}</p>
                <div className="d-row d-gap-8" style={{ marginTop: 6 }}>
                  <span className="d-tag d-tag-lg">{pack.lane === 'between' ? 'Between databases' : pack.lane === 'shared' ? 'For every database' : `For ${laneOf(pack)}`}</span>
                  <span className="d-tag d-tag-lg">{count(rules.length, 'rule')}</span>
                  <span className="d-tag d-tag-lg d-mono">@rule:{pack.id}</span>
                </div>
              </div>
              <div className="d-rc-used">
                <span className="d-caps d-caps-sm">Used by</span>
                {users.map((u) => <a key={u} className="d-mono d-small" href={`#/${encodeURIComponent(u)}/rules`}>@{u}</a>)}
                {!users.length && <span className="d-soft d-small">No schema yet</span>}
              </div>
            </div>

            <div className="d-tbl">
              <div className="d-rc-row d-tbl-head d-rhead"><span>Rule</span><span>By default</span><span>Reference</span></div>
              {rules.map((r) => (
                <div key={r.id} className="d-rc-row d-rc-line">
                  <span className="d-col d-gap-4">
                    <span className="d-strong">{r.title}</span>
                    <span className="d-small d-soft">{r.why}</span>
                  </span>
                  <span className={`d-held d-held-${r.strength === 'must' ? 'hard' : 'soft'}`}>{r.strength === 'must' ? 'Hard' : 'Soft'}</span>
                  <span className="d-mono d-xsmall" style={{ color: 'var(--d-lilac)', overflowWrap: 'anywhere' }}>@rule:{r.id}</span>
                </div>
              ))}
            </div>

            <div className="d-band" style={{ gap: 6, padding: '16px 20px' }}>
              <span className="d-strong">Hard and soft</span>
              <span className="d-small d-soft">
                <b style={{ color: 'var(--d-gold)' }}>Hard</b>: a change that breaks it is refused, the agent's and yours. <b style={{ color: 'var(--d-lilac)' }}>Soft</b>: the change lands and the break is listed. Each rule has a default; you choose when you link a pack to a schema.
              </span>
            </div>
          </main>
        )}
      </div>
    </div>
  )
}
