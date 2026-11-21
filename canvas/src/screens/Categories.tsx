// Categories, as the "Perspective · Categories" board draws it: the schema by namespace, then by family; each family
// a card in its colour, with what it is, where it links, and its tables to open.

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
    <main className="d-persp-main" style={{ gap: 32 }}>
      {namespaces.map((n) => {
        const fams = [...ix.families.values()].filter((f) => f.namespace === n.id)
        const count = fams.reduce((k, f) => k + f.tables.length, 0)
        return (
          <section key={n.id} className="d-col" style={{ gap: 14 }}>
            <div className="d-row" style={{ alignItems: 'baseline', gap: 12 }}>
              <span className="d-kicker">namespace</span>
              <h2 className="d-cat-ns">{ix.path(n.id)}</h2>
              <span className="d-soft">{count} tables</span>
            </div>
            <div className="d-cat-grid">
              {fams.map((f) => {
                const out = linksOut(f.key)
                const sorted = [...f.tables].sort((a, b) => a.name.localeCompare(b.name))
                return (
                  <div key={f.key} className="d-cat-card" style={{ borderTopColor: f.color }}>
                    <div className="d-row" style={{ justifyContent: 'space-between', alignItems: 'baseline', gap: 10 }}>
                      <button type="button" className="d-cat-name" style={{ color: f.color }} onClick={() => go('map', f.key)} title="See how it links">{f.name}</button>
                      <span className="d-small d-soft">{f.tables.length} tables{f.copies ? ` (+${f.copies} copies)` : ''}</span>
                    </div>
                    {out && <span className="d-small d-soft">Links: {out}.</span>}
                    <div className="d-cat-list">
                      {sorted.map((t) => (
                        <button key={t.id} type="button" className="d-cat-row" onClick={() => go('table', t.id)}>
                          <span className="d-mono" style={{ fontSize: 13, overflowWrap: 'anywhere' }}>{t.name}</span>
                          <span className="d-xsmall d-soft" style={{ flexShrink: 0 }}>{t.columns.length} cols</span>
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
    </main>
  )
}
