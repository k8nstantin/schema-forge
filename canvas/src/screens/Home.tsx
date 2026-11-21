// Home, as the "1 · Home" board draws it: start a schema, open one, or manage the rules; and how you and the agent
// work together.

import { useEffect, useState } from 'react'

import { recent, schemaRules, schemas as fetchSchemas, model as fetchModel, workspace as fetchWorkspace, type Operation, type Workspace } from '../api'
import type { Catalog, SchemaInfo } from '../model'
import { Brand, ago, targetLabel, who } from './parts'

interface Row {
  info: SchemaInfo
  tables: number
  views: number
  packs: number
  last?: Operation
}

export function Home({ catalog, version, open, newSchema, rules }: {
  catalog: Catalog | null
  version: number
  open: (name: string) => void
  newSchema: () => void
  rules: () => void
}) {
  const [rows, setRows] = useState<Row[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [ws, setWs] = useState<Workspace | null>(null)
  useEffect(() => {
    const read = () => fetchWorkspace().then(setWs, () => undefined)
    read()
    const t = window.setInterval(read, 15000)
    return () => window.clearInterval(t)
  }, [version])
  useEffect(() => {
    const isPack = (id: string) => !!catalog?.rules.find((r) => r.id === id)?.rules?.length
    fetchSchemas()
      .then((infos) =>
        Promise.all(
          infos.map(async (info) => {
            const [m, r, ops] = await Promise.all([
              fetchModel(info.name).catch(() => null),
              schemaRules(info.name).catch(() => null),
              recent(info.name, 1).catch(() => []),
            ])
            const linked = new Set([...(r?.global ?? []), ...(r?.links ?? [])].filter((l) => !l.off && isPack(l.rule)).map((l) => l.rule))
            return { info, tables: m?.tables?.length ?? 0, views: m?.views?.length ?? 0, packs: linked.size, last: ops[0] }
          }),
        ),
      )
      .then(setRows, (e) => setError(String(e.message ?? e)))
  }, [version, catalog])

  const packs = catalog?.rules.filter((r) => r.rules?.length) ?? []
  const checks = catalog?.rules.filter((r) => !r.rules?.length) ?? []
  const using = rows?.filter((r) => r.packs > 0).length ?? 0
  // Connected: the agent reached the MCP in the last ten minutes.
  const connected = !!ws?.agent_seen && ws.now - ws.agent_seen < 10 * 60 * 1000
  return (
    <div className="d-page">
      <header className="d-bar">
        <Brand />
        <div className="d-pill">
          <span className={`d-dot${connected ? '' : ' d-dot-idle'}`} />
          <span>{connected ? 'Claude Code is connected through the MCP' : <>Waiting for Claude Code on the MCP at <span className="d-ref">/mcp</span></>}</span>
        </div>
      </header>

      <main className="d-main">
        <div className="d-col d-gap-8">
          <h1 className="d-h1">What do you want to work on?</h1>
          <p className="d-lead">
            Set a schema up once: its name, its type and its rules. The agent reads them through the MCP, so you never
            repeat them in a prompt.
          </p>
        </div>

        <div className="d-grid-cards">
          <button type="button" className="d-card" onClick={newSchema}>
            <div className="d-card-icon d-card-icon-on">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#ffffff" strokeWidth="2" strokeLinecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg>
            </div>
            <div className="d-col d-gap-6">
              <span className="d-card-title">New schema</span>
              <span className="d-soft">Start a schema from nothing, or from a dump or an Iceberg folder you import.</span>
            </div>
            <ol className="d-steps">
              <li><span className="d-num">1</span>Name it</li>
              <li><span className="d-num">2</span>Pick its type: PostgreSQL, MySQL or Iceberg</li>
              <li><span className="d-num">3</span>Add its rules</li>
              <li><span className="d-num">4</span>Hand it to the agent</li>
            </ol>
            <span className="d-btn" style={{ marginTop: 'auto' }}>Create a schema</span>
          </button>

          <div className="d-card">
            <div className="d-card-icon">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#dda9ff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M3 7h6l2 2h10v10H3z" /></svg>
            </div>
            <div className="d-col d-gap-6">
              <span className="d-card-title">Open a schema</span>
              <span className="d-soft">Pick up where you or the agent left off.</span>
            </div>
            <div className="d-col d-gap-8">
              {error && <span className="d-error">{error}</span>}
              {!rows && !error && <span className="d-soft d-small">Reading the workspace…</span>}
              {rows?.length === 0 && <span className="d-soft d-small">No schemas yet. Create one, or import a dump with <span className="d-ref">schema-forge import</span>.</span>}
              {rows?.map((r) => (
                <button key={r.info.name} type="button" className="d-item" onClick={() => open(r.info.name)}>
                  <span className="d-item-head">
                    <span style={{ fontWeight: 600, fontSize: 16 }}>{r.info.name}</span>
                    <span className="d-tag">{targetLabel(r.info)}</span>
                  </span>
                  <span className="d-soft d-xsmall">{summary(r)}</span>
                </button>
              ))}
            </div>
            <a className="d-btn d-btn-line d-btn-sm" href="#/_open">Open a file or folder…</a>
            {rows && rows.length > 0 && (
              <span className="d-soft d-small" style={{ marginTop: 'auto' }}>
                {rows.length === 1 ? 'The schema is' : `All ${rows.length} schemas are`} in <span className="d-ref">{ws?.folder ?? 'this workspace'}</span>
              </span>
            )}
          </div>

          <button type="button" className="d-card" onClick={rules}>
            <div className="d-card-icon">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#dda9ff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M9 11l2 2 4-4" /><path d="M5 4h14v16H5z" /></svg>
            </div>
            <div className="d-col d-gap-6">
              <span className="d-card-title">Rules</span>
              <span className="d-soft">Your standards, in packs you add to any schema. The agent follows them and the tool checks them.</span>
            </div>
            <div className="d-row d-gap-8">
              {packs.slice(0, 6).map((p) => <span key={p.id} className="d-chip">{p.title}</span>)}
            </div>
            {catalog && (
              <span className="d-soft d-small">
                {packs.length} packs · {checks.length} rules · used by {using} {using === 1 ? 'schema' : 'schemas'}
              </span>
            )}
            <span className="d-btn d-btn-accent-line" style={{ marginTop: 'auto' }}>Manage rules</span>
          </button>
        </div>

        <section className="d-band">
          <span className="d-caps">How you and the agent work</span>
          <div className="d-band-grid">
            <div className="d-col d-gap-4"><span className="d-strong">You set it up</span><span className="d-soft d-small">Name, type and rules, here, once.</span></div>
            <div className="d-col d-gap-4"><span className="d-strong">You prompt the agent</span><span className="d-soft d-small">"Design <span className="d-ref">@{rows?.[0]?.info.name ?? 'shop'}</span>: orders with history." Nothing else to explain.</span></div>
            <div className="d-col d-gap-4"><span className="d-strong">The agent builds through the MCP</span><span className="d-soft d-small">Every change is checked against the schema's rules.</span></div>
            <div className="d-col d-gap-4"><span className="d-strong">You watch and steer</span><span className="d-soft d-small">Changes land live. Copy a reference to point the agent at anything.</span></div>
          </div>
        </section>
      </main>
    </div>
  )
}

function summary(r: Row): string {
  const parts = [`${r.tables} ${r.tables === 1 ? 'table' : 'tables'}`]
  if (r.views) parts.push(`${r.views} ${r.views === 1 ? 'view' : 'views'}`)
  parts.push(r.packs ? `${r.packs} rule ${r.packs === 1 ? 'pack' : 'packs'}` : 'no rules')
  if (r.last) {
    const when = r.last.at ? ` ${ago(r.last.at)}` : ''
    parts.push(r.last.kind === 'import' ? `imported${when}` : r.last.at ? `${who(r.last.by)} changed it${when}` : `last changed by ${who(r.last.by)}`)
  }
  return parts.join(' · ')
}
