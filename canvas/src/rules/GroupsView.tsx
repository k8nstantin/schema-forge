// Groups: tables picked by hand, across namespaces and families, so a rule can be linked to exactly them.

import { useMemo, useState } from 'react'

import { removeGroup, setGroup } from '../api'
import { useWorkbench } from '../state'

export function GroupsView() {
  const { name, model, ix, go, rules, reloadRules } = useWorkbench()
  const [editing, setEditing] = useState<string | null>(null)
  const [title, setTitle] = useState('')
  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [query, setQuery] = useState('')
  const [error, setError] = useState<string | null>(null)
  const found = useMemo(() => {
    const q = query.trim().toLowerCase()
    return (model.tables ?? []).filter((t) => !ix.isCopy(t.id) && (!q || t.name.toLowerCase().includes(q))).slice(0, 200)
  }, [model, ix, query])
  const edit = (g?: { name: string; tables: string[] }) => {
    setEditing(g?.name ?? '')
    setTitle(g?.name ?? '')
    setPicked(new Set(g?.tables ?? []))
    setError(null)
  }
  const act = (p: Promise<unknown>, then?: () => void) => p.then(() => { setError(null); reloadRules(); then?.() }, (e) => setError(String(e.message ?? e)))
  return (
    <div className="sf-page">
      <div className="sf-row-between">
        <span className="sf-about">A group is tables you pick, across namespaces and families, to link rules to exactly them: say the tables CDC streams into.</span>
        <button type="button" className="sf-button" onClick={() => edit()}>New group</button>
      </div>
      <div className="sf-cards">
        {rules.groups.map((g) => (
          <div key={g.name} className="sf-famcard">
            <div className="sf-row-between">
              <button type="button" className="sf-link sf-famname" onClick={() => go('rules', `level:group:${g.name}`)}>{g.name}</button>
              <span className="sf-muted sf-small">{g.tables.length} tables · {rules.links.filter((l) => l.at.level === 'group' && l.at.group === g.name).length} rules</span>
            </div>
            <div className="sf-chips">{g.tables.map((t) => <span key={t} className="sf-chip sf-static">{ix.tables.get(t)?.name ?? t}</span>)}</div>
            <span className="sf-row-gap">
              <button type="button" className="sf-chip" onClick={() => edit(g)}>Change</button>
              <button type="button" className="sf-chip" onClick={() => act(removeGroup(name, g.name))}>Take away</button>
            </span>
          </div>
        ))}
        {rules.groups.length === 0 && <span className="sf-muted">No groups yet.</span>}
      </div>
      {editing !== null && (
        <section className="sf-actions sf-col">
          <label className="sf-field"><span className="sf-caption">Name</span><input className="sf-input" value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Streamed by CDC" disabled={editing !== ''} /></label>
          <label className="sf-field"><span className="sf-caption">Tables · {picked.size} picked</span><input className="sf-input" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Find a table" /></label>
          <div className="sf-pickgrid">
            {found.map((t) => (
              <label key={t.id} className="sf-check">
                <input type="checkbox" checked={picked.has(t.id)} onChange={(e) => { const n = new Set(picked); if (e.target.checked) n.add(t.id); else n.delete(t.id); setPicked(n) }} />
                <span className="sf-mono">{t.name}</span><span className="sf-muted sf-small">{ix.path(t.namespace)}</span>
              </label>
            ))}
          </div>
          <span className="sf-row-gap">
            <button type="button" className="sf-button" disabled={!title.trim() || picked.size === 0} onClick={() => act(setGroup(name, { name: title.trim(), tables: [...picked] }), () => setEditing(null))}>Keep the group</button>
            <button type="button" className="sf-chip" onClick={() => setEditing(null)}>Cancel</button>
          </span>
          {error && <span className="sf-error" role="alert">{error}</span>}
        </section>
      )}
    </div>
  )
}
