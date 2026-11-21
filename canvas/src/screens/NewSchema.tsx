// New schema, as the "2 · New schema" board draws it: name it, pick its type, add its rules, hand it to the agent.
// A new schema has no rules until you turn a pack on; each pack you turn on holds hard or soft, as you choose.

import { useState } from 'react'

import { linkRule, newSchema } from '../api'
import type { Catalog, Enforce, Target } from '../model'
import { Brand } from './parts'

const TYPES: { id: Target; label: string; what: string; has: string }[] = [
  { id: 'postgres', label: 'PostgreSQL', what: 'Tables, views, enums, partitions, foreign keys, checks.', has: 'Reads a pg_dump · writes PostgreSQL DDL' },
  { id: 'mysql', label: 'MySQL', what: 'Tables, views, foreign keys, InnoDB options.', has: 'Designed here · reading a mysqldump and writing MySQL DDL are not built yet' },
  { id: 'iceberg', label: 'Iceberg', what: 'Tables with nested types, partition transforms, sort orders and properties. No foreign keys.', has: 'Reads Spark SQL · writes Spark SQL' },
]
const STEPS = ['Name', 'Type', 'Rules', 'Agent']

export function NewSchema({ catalog, open }: { catalog: Catalog | null; open: (name: string) => void }) {
  const [step, setStep] = useState(0)
  const [name, setName] = useState('')
  const [about, setAbout] = useState('')
  const [type, setType] = useState<Target>('postgres')
  const [version, setVersion] = useState<2 | 3>(3)
  const [on, setOn] = useState<Record<string, Enforce>>({})
  const [made, setMade] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  const valid = /^[a-z][a-z0-9_-]{0,62}$/.test(name)
  const label = TYPES.find((t) => t.id === type)!.label
  const checksOf = (id: string): string[] => {
    const r = catalog?.rules.find((x) => x.id === id)
    return r?.rules?.length ? r.rules.flatMap(checksOf) : [id]
  }
  const fits = (id: string) => {
    const r = catalog?.rules.find((x) => x.id === id)
    return !r?.targets?.length || r.targets.includes(type)
  }
  const packs = (catalog?.rules ?? []).filter((r) => r.rules?.length && fits(r.id))
  const chosen = packs.filter((p) => on[p.id])
  const ruleCount = new Set(chosen.flatMap((p) => checksOf(p.id).filter(fits))).size
  const prompt = `Design @${name || 'name'}: `

  // Made once; the packs are linked one by one after it, and a try again links only those not linked yet.
  const [created, setCreated] = useState<string | null>(null)
  const [linked, setLinked] = useState<Set<string>>(new Set())
  const create = () => {
    setBusy(true)
    setError(null)
    let schemaMade = created === name
    const made = schemaMade ? Promise.resolve() : newSchema(name, type, about, type === 'iceberg' ? version : undefined).then(() => { schemaMade = true; setCreated(name) })
    made
      .then(async () => {
        for (const p of chosen.filter((x) => !linked.has(x.id))) {
          await linkRule(name, { rule: p.id, at: { level: 'schema' }, enforce: on[p.id] })
          setLinked((l) => new Set([...l, p.id]))
        }
      })
      .then(() => { setMade(true); setStep(3) }, (e) => setError(`${String(e.message ?? e)}${schemaMade ? ' The schema is made; try again to link the rest, or change the packs.' : ''}`))
      .finally(() => setBusy(false))
  }

  return (
    <div className="d-page">
      <header className="d-bar">
        <Brand />
        <a href="#/" className="d-small">{made ? 'Home' : 'Cancel'}</a>
      </header>

      <main className="d-main d-main-form">
        <h1 className="d-h1 d-h1-page">New schema</h1>

        <nav aria-label="Steps" className="d-wizard">
          {STEPS.map((l, i) => {
            // Every step is open from the start, so the type is never hidden behind the name; the last needs the schema.
            const reach = made ? i === 3 : i < 3
            return (
              <button key={l} type="button" disabled={!reach} onClick={() => setStep(i)}
                className={`d-wstep${i === step ? ' d-wstep-on' : i < step ? ' d-wstep-done' : ''}`}>
                <span className="d-caps d-caps-sm" style={{ color: 'inherit' }}>Step {i + 1}</span>
                <span style={{ fontSize: 16, fontWeight: 600 }}>{l}</span>
              </button>
            )
          })}
        </nav>

        {step === 0 && (
          <section className="d-panel">
            <div className="d-col d-gap-4">
              <h2 className="d-h2">Name it</h2>
              <p className="d-soft" style={{ margin: 0 }}>You and the agent use this name to point at the schema, as <span className="d-ref">@{name || 'name'}</span>.</p>
            </div>
            <label className="d-field" style={{ maxWidth: 520 }}>
              <span className="d-label">Schema name</span>
              <input className="d-input d-input-mono" value={name} onChange={(e) => setName(e.target.value)} placeholder="orders_lake" autoFocus />
              <span className="d-xsmall" style={{ color: name && !valid ? 'var(--d-red)' : 'var(--d-soft)' }}>
                {name && !valid ? 'Start with a letter; then lower case letters, digits, - and _.' : 'Lower case letters, digits, - and _.'}
              </span>
            </label>
            <label className="d-field" style={{ maxWidth: 720 }}>
              <span className="d-label">What it is for <span style={{ fontWeight: 400 }} className="d-soft">(optional, the agent reads it too)</span></span>
              <textarea className="d-input" rows={3} value={about} onChange={(e) => setAbout(e.target.value)} style={{ resize: 'vertical' }}
                placeholder="Orders and customers from the shop's PostgreSQL, landed in the lake through CDC, with full history." />
            </label>
            <div className="d-row">
              <button type="button" className="d-btn" disabled={!valid} onClick={() => setStep(1)}>Next: pick its type</button>
              <span className="d-soft d-small">Or <a href="#/_open">import a pg_dump or an Iceberg folder</a> instead.</span>
            </div>
          </section>
        )}

        {step === 1 && (
          <section className="d-panel">
            <div className="d-col d-gap-4">
              <h2 className="d-h2">Pick its type</h2>
              <p className="d-soft" style={{ margin: 0 }}>One type per schema. It decides the data types, the options and the SQL the agent writes.</p>
            </div>
            <div className="d-pick-grid">
              {TYPES.map((t) => (
                <button key={t.id} type="button" aria-pressed={type === t.id} onClick={() => { setType(t.id); setOn({}) }}
                  className={`d-pick${type === t.id ? ' d-pick-on' : ''}`}>
                  <span className="d-item-head">
                    <span className="d-pick-title">{t.label}</span>
                    {type === t.id && <span className="d-badge">Selected</span>}
                  </span>
                  <span className="d-soft d-small">{t.what}</span>
                  <span className="d-xsmall" style={{ color: 'var(--d-lilac)' }}>{t.has}</span>
                </button>
              ))}
            </div>
            {type === 'iceberg' && (
              <div className="d-col d-gap-10">
                <span className="d-label">Iceberg format version</span>
                <div className="d-row d-gap-8">
                  {([3, 2] as const).map((v) => (
                    <button key={v} type="button" aria-pressed={version === v} onClick={() => setVersion(v)}
                      className={`d-seg${version === v ? ' d-seg-on' : ''}`}>
                      {v === 3 ? 'Format v3 (default)' : 'Format v2'}
                    </button>
                  ))}
                </div>
              </div>
            )}
            <div className="d-row">
              <button type="button" className="d-btn d-btn-line" onClick={() => setStep(0)}>Back</button>
              <button type="button" className="d-btn" onClick={() => setStep(2)}>Next: add its rules</button>
            </div>
          </section>
        )}

        {step === 2 && (
          <section className="d-panel">
            <div className="d-row" style={{ justifyContent: 'space-between', alignItems: 'flex-end' }}>
              <div className="d-col d-gap-4">
                <h2 className="d-h2">Add its rules</h2>
                <p className="d-soft" style={{ margin: 0 }}>
                  Packs that fit {label} are listed. A new schema has none: turn on the ones it follows, hard or soft. You can change them later.
                </p>
              </div>
              <span className="d-small" style={{ color: 'var(--d-lilac)' }}>{chosen.length} packs on · {ruleCount} rules</span>
            </div>
            <div className="d-col d-gap-10">
              {packs.map((p) => {
                const how = on[p.id]
                const toggle = () => setOn((o) => {
                  const n = { ...o }
                  if (n[p.id]) delete n[p.id]
                  else n[p.id] = 'soft'
                  return n
                })
                return (
                  <div key={p.id} className={`d-pack${how ? ' d-pack-on' : ''}`}>
                    <button type="button" className="d-switch" role="switch" aria-checked={!!how} aria-label={`${p.title}: ${how ? 'on' : 'off'}`} onClick={toggle}>
                      <span className="d-knob" />
                    </button>
                    <button type="button" className="d-pack-text" onClick={toggle}>
                      <span className="d-row d-gap-10" style={{ alignItems: 'baseline' }}>
                        <span className="d-strong" style={{ fontSize: 16 }}>{p.title}</span>
                        <span className="d-soft d-xsmall">{checksOf(p.id).filter(fits).length} rules</span>
                      </span>
                      <span className="d-soft d-small">{p.why}</span>
                    </button>
                    {how && (
                      <div className="d-hardsoft" role="radiogroup" aria-label={`How ${p.title} holds`}>
                        {(['soft', 'hard'] as const).map((e) => (
                          <button key={e} type="button" role="radio" aria-checked={how === e} onClick={() => setOn((o) => ({ ...o, [p.id]: e }))}
                            className={`d-hs${how === e ? ` d-hs-${e}` : ''}`}>
                            {e === 'hard' ? 'Hard' : 'Soft'}
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
            <span className="d-soft d-small">
              <b className="d-strong">Hard</b>: a change that breaks it is refused, for the agent and for you. <b className="d-strong">Soft</b>: the change lands and the break is highlighted.
              {' '}Need something else? <a href="#/_rules">Make a pack in Rules</a>.
            </span>
            {error && <span className="d-error">{error}</span>}
            <div className="d-row">
              <button type="button" className="d-btn d-btn-line" onClick={() => setStep(1)}>Back</button>
              <button type="button" className="d-btn" disabled={busy || !valid} onClick={create}>{busy ? 'Creating…' : created === name ? 'Link the packs' : 'Create the schema'}</button>
            </div>
          </section>
        )}

        {step === 3 && made && (
          <section className="d-panel" style={{ gap: 24 }}>
            <div className="d-col d-gap-4">
              <h2 className="d-h2">Ready for the agent</h2>
              <p className="d-soft" style={{ margin: 0 }}>The agent reads all of this through the MCP. Your prompt only has to say what to build.</p>
            </div>
            <div className="d-band-grid" style={{ gap: 16 }}>
              <div className="d-fact"><span className="d-caps d-caps-sm">Schema</span><span className="d-mono" style={{ fontSize: 18, color: 'var(--d-bright)' }}>@{name}</span></div>
              <div className="d-fact"><span className="d-caps d-caps-sm">Type</span><span style={{ fontSize: 18, color: 'var(--d-bright)' }}>{type === 'iceberg' ? `Iceberg, format v${version}` : label}</span></div>
              <div className="d-fact">
                <span className="d-caps d-caps-sm">Rules</span>
                <span style={{ fontSize: 18, color: 'var(--d-bright)' }}>{chosen.length ? `${chosen.length} packs, ${ruleCount} rules` : 'None yet'}</span>
                <span className="d-soft d-xsmall">{chosen.map((p) => `${p.title} (${on[p.id]})`).join(' · ') || 'Add them in Rules whenever you choose.'}</span>
              </div>
            </div>
            <div className="d-col d-gap-10">
              <span className="d-label">Paste this into Claude Code to start</span>
              <div className="d-row" style={{ alignItems: 'stretch' }}>
                <code className="d-code">{prompt}</code>
                <button type="button" className="d-btn d-btn-accent-line"
                  onClick={() => navigator.clipboard.writeText(prompt).then(() => setCopied(true), () => setCopied(false))}>
                  {copied ? 'Copied' : 'Copy'}
                </button>
              </div>
              <span className="d-soft d-small">Then add what you want built, in your own words. The agent fetches the type and every rule itself.</span>
            </div>
            <div className="d-row">
              <button type="button" className="d-btn" onClick={() => open(name)}>Open the schema and watch</button>
              <a className="d-btn d-btn-line" href={`#/${encodeURIComponent(name)}/rules`}>Change the rules</a>
            </div>
          </section>
        )}
      </main>
    </div>
  )
}
