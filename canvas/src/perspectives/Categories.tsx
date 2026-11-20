// Categories: the schema by namespace, then family, each family a card listing its tables and where it links.

import { useWorkbench } from '../state'

export function Categories() {
  const { model, ix, go } = useWorkbench()
  const namespaces = [...ix.namespaces.values()].filter((n) => (model.tables ?? []).some((t) => t.namespace === n.id))
  const linksOut = (key: string) => {
    const fam = ix.families.get(key)!
    const to = new Map<string, number>()
    for (const t of fam.tables) for (const l of ix.out.get(t.id) ?? []) {
      const f = ix.familyOf(l.to)
      if (f && f.key !== key) to.set(f.key, (to.get(f.key) ?? 0) + 1)
    }
    return [...to].sort((a, b) => b[1] - a[1]).map(([k, n]) => `${n} → ${ix.families.get(k)!.name}`).join(' · ')
  }
  return (
    <div className="sf-page sf-gap-xl">
      {namespaces.map((n) => {
        const fams = [...ix.families.values()].filter((f) => f.namespace === n.id)
        const count = fams.reduce((k, f) => k + f.tables.length, 0)
        return (
          <section key={n.id} className="sf-col">
            <div className="sf-nstitle">
              <span className="sf-caption">namespace</span>
              <h2 className="sf-ns sf-ns-big">{ix.path(n.id)}</h2>
              <span className="sf-muted">{count} tables · {fams.length} {fams.length === 1 ? 'family' : 'families'}</span>
            </div>
            <div className="sf-cards">
              {fams.map((f) => {
                const out = linksOut(f.key)
                return (
                  <div key={f.key} className="sf-famcard" style={{ borderTopColor: f.color }}>
                    <div className="sf-row-between">
                      <span className="sf-famname" style={{ color: f.color }}>{f.name}</span>
                      <span className="sf-muted">{f.tables.length} tables{f.copies ? ` (+${f.copies} copies)` : ''}</span>
                    </div>
                    {out && <span className="sf-muted">Links: {out}</span>}
                    <div className="sf-famlist">
                      {f.tables.map((t) => (
                        <button key={t.id} type="button" className="sf-famrow" onClick={() => go('table', t.id)}>
                          <span className="sf-mono">{t.name}</span>
                          <span className="sf-muted">{t.columns.length} cols</span>
                        </button>
                      ))}
                    </div>
                  </div>
                )
              })}
            </div>
          </section>
        )
      })}
    </div>
  )
}
