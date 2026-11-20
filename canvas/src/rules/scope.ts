// Levels of the hierarchy, as the rules perspective walks them: a level's key in the address, its name in words,
// the tables under it and the levels inside it.

import type { RuleGroup, Scope, Table } from '../model'
import type { Index } from '../state'

/// A level as one token for the address: `schema`, `ns:<id>`, `fam:<namespace>/<family>`, `group:<name>`, `table:<id>`.
export function scopeKey(s: Scope): string {
  switch (s.level) {
    case 'global': return 'global'
    case 'schema': return 'schema'
    case 'namespace': return `ns:${s.namespace}`
    case 'family': return `fam:${s.namespace}/${s.family}`
    case 'group': return `group:${s.group}`
    case 'table': return `table:${s.table}`
  }
}

export function parseScope(key: string | undefined): Scope {
  if (!key || key === 'schema') return { level: 'schema' }
  if (key === 'global') return { level: 'global' }
  const [kind, ...rest] = key.split(':')
  const v = rest.join(':')
  if (kind === 'ns') return { level: 'namespace', namespace: v }
  if (kind === 'fam') return { level: 'family', namespace: v.slice(0, v.indexOf('/')), family: v.slice(v.indexOf('/') + 1) }
  if (kind === 'group') return { level: 'group', group: v }
  if (kind === 'table') return { level: 'table', table: v }
  return { level: 'schema' }
}

export const sameScope = (a: Scope, b: Scope) => scopeKey(a) === scopeKey(b)

/// The level's kind, for captions.
export const levelName = (s: Scope) => (s.level === 'namespace' ? 'namespace' : s.level)

/// The level in words: `analytics.sales`, `node__`, `Streamed by CDC`, `orders`.
export function scopeTitle(ix: Index, name: string, s: Scope): string {
  switch (s.level) {
    case 'global': return 'Every schema'
    case 'schema': return name
    case 'namespace': return ix.path(s.namespace)
    case 'family': return s.family
    case 'group': return s.group
    case 'table': return ix.tables.get(s.table)?.name ?? s.table
  }
}

/// Whether namespace `inner` is `outer` or inside it.
function within(ix: Index, inner: string, outer: string): boolean {
  for (let n: string | undefined = inner, i = 0; n && i < 64; n = ix.namespaces.get(n)?.parent, i++) if (n === outer) return true
  return false
}

/// Whether `t` is under the level `s`.
export function holds(ix: Index, groups: RuleGroup[], s: Scope, t: Table): boolean {
  switch (s.level) {
    case 'global':
    case 'schema': return true
    case 'namespace': return within(ix, t.namespace, s.namespace)
    case 'family': return t.namespace === s.namespace && ix.familyOf(t.id)?.name === s.family
    case 'group': return groups.some((g) => g.name === s.group && g.tables.includes(t.id))
    case 'table': return t.id === s.table
  }
}

export interface Level { scope: Scope; caption: string; title: string; tables: Table[] }

/// The levels directly inside `s`: a schema's namespaces and groups, a namespace's namespaces and families, the
/// tables of a family or a group, and the groups a table is in.
export function childrenOf(ix: Index, all: Table[], groups: RuleGroup[], name: string, s: Scope): Level[] {
  const level = (scope: Scope, caption: string): Level => ({ scope, caption, title: scopeTitle(ix, name, scope), tables: all.filter((t) => holds(ix, groups, scope, t)) })
  const tablesOf = (ids: string[]) => ids.map((id) => ix.tables.get(id)).filter((t): t is Table => !!t).map((t) => level({ level: 'table', table: t.id }, 'table'))
  switch (s.level) {
    case 'global':
    case 'schema':
      return [
        ...[...ix.namespaces.values()].filter((n) => !n.parent && all.some((t) => within(ix, t.namespace, n.id))).map((n) => level({ level: 'namespace', namespace: n.id }, 'namespace')),
        ...groups.map((g) => level({ level: 'group', group: g.name }, 'group')),
      ]
    case 'namespace':
      return [
        ...[...ix.namespaces.values()].filter((n) => n.parent === s.namespace).map((n) => level({ level: 'namespace', namespace: n.id }, 'namespace')),
        ...[...ix.families.values()].filter((f) => f.namespace === s.namespace).map((f) => level({ level: 'family', namespace: f.namespace, family: f.name }, 'family')),
      ]
    case 'family': return tablesOf(ix.families.get(`${s.namespace}/${s.family}`)?.tables.map((t) => t.id) ?? [])
    case 'group': return tablesOf(groups.find((g) => g.name === s.group)?.tables ?? [])
    case 'table': return groups.filter((g) => g.tables.includes(s.table)).map((g) => level({ level: 'group', group: g.name }, 'in group'))
  }
}

/// The levels from the widest down to `s`, for the breadcrumb.
export function path(ix: Index, s: Scope): Scope[] {
  const nsChain = (id: string) => {
    const out: Scope[] = []
    for (let n: string | undefined = id, i = 0; n && i < 64; n = ix.namespaces.get(n)?.parent, i++) out.unshift({ level: 'namespace', namespace: n })
    return out
  }
  switch (s.level) {
    case 'global':
    case 'schema': return [{ level: 'schema' }]
    case 'namespace': return [{ level: 'schema' }, ...nsChain(s.namespace)]
    case 'family': return [{ level: 'schema' }, ...nsChain(s.namespace), s]
    case 'group': return [{ level: 'schema' }, s]
    case 'table': {
      const t = ix.tables.get(s.table)
      const fam = t && ix.familyOf(t.id)
      return [{ level: 'schema' }, ...(t ? nsChain(t.namespace) : []), ...(fam ? [{ level: 'family', namespace: fam.namespace, family: fam.name } as Scope] : []), s]
    }
  }
}
