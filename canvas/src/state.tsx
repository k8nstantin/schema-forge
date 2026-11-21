// What every perspective shares: the open schema, its model and shape, lookups over both, where you are, and
// what you point at, which a reference (`@orders.total`) names for the agent.

import { createContext, useContext, useMemo, type ReactNode } from 'react'

import { typeLabel, type Catalog, type Column, type Schema, type SchemaRules, type Shape, type Table } from './model'

export type Perspective = 'tables' | 'categories' | 'table' | 'map' | 'rules'

/// What you point at: a table, or one of its columns.
export type Pointer = { kind: 'table'; table: string } | { kind: 'column'; table: string; column: string } | null

export interface Workbench {
  name: string
  model: Schema
  shape: Shape
  ix: Index
  go: (perspective: Perspective, arg?: string) => void
  pointer: Pointer
  point: (p: Pointer) => void
  /// Every built-in rule, goal and type map.
  catalog: Catalog
  /// The schema's links, groups, and the schema checked against them.
  rules: SchemaRules
  /// Reads the rules again, after a change made here (the change also arrives live).
  reloadRules: () => void
  /// Changes the design by hand: the same operations the agent uses. Asks before a destructive one or one that breaks
  /// a hard rule; true when it landed.
  edit: (operations: unknown[]) => Promise<boolean>
}

const Context = createContext<Workbench | null>(null)

export function WorkbenchProvider({ value, children }: { value: Omit<Workbench, 'ix'>; children: ReactNode }) {
  const ix = useMemo(() => indexOf(value.model, value.shape), [value.model, value.shape])
  return <Context.Provider value={{ ...value, ix }}>{children}</Context.Provider>
}

export function useWorkbench(): Workbench {
  const w = useContext(Context)
  if (!w) throw new Error('outside a schema')
  return w
}

/// A palette checked for colour-blind separation on this background. Green and red are left out: they mean
/// "passes" and "breaks" wherever they appear.
const PALETTE = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181', '#9085e9']

export interface Family {
  key: string
  namespace: string
  name: string
  color: string
  tables: Table[]
  copies: number
}

export interface Link {
  from: string
  column: string
  to: string
  declared: boolean
}

export function indexOf(model: Schema, shape: Shape) {
  const tables = new Map<string, Table>((model.tables ?? []).map((t) => [t.id, t]))
  const namespaces = new Map((model.namespaces ?? []).map((n) => [n.id, n]))
  const columns = new Map<string, { table: Table; column: Column }>()
  for (const t of model.tables ?? []) for (const c of t.columns) columns.set(c.id, { table: t, column: c })
  const typeNames = new Map((model.types ?? []).map((t) => [t.id, t.name]))
  const placed = new Map(shape.tables.map((p) => [p.table, p]))
  const isCopy = (id: string) => !!placed.get(id)?.copy_of
  const nameCount = new Map<string, number>()
  for (const t of model.tables ?? []) nameCount.set(t.name, (nameCount.get(t.name) ?? 0) + 1)
  const path = (namespace: string): string => {
    const n = namespaces.get(namespace)
    if (!n) return ''
    return n.parent ? `${path(n.parent)}.${n.name}` : n.name
  }
  // Families, biggest first; colour follows the family when there are few, else the namespace.
  const famKey = (t: Table) => `${t.namespace}/${placed.get(t.id)?.family ?? 'ungrouped'}`
  const byFamily = new Map<string, Table[]>()
  for (const t of model.tables ?? []) {
    if (isCopy(t.id)) continue
    const k = famKey(t)
    if (!byFamily.has(k)) byFamily.set(k, [])
    byFamily.get(k)!.push(t)
  }
  const famKeys = [...byFamily.keys()].sort((a, b) => byFamily.get(b)!.length - byFamily.get(a)!.length || a.localeCompare(b))
  const nsList = [...new Set(famKeys.map((k) => k.slice(0, k.indexOf('/'))))]
  const byFamilyColour = famKeys.length <= PALETTE.length
  const families = new Map<string, Family>(
    famKeys.map((k, i) => {
      const namespace = k.slice(0, k.indexOf('/'))
      const name = k.slice(k.indexOf('/') + 1)
      const color = byFamilyColour ? PALETTE[i] : nsList.length <= PALETTE.length ? PALETTE[nsList.indexOf(namespace)] : '#8f7ba5'
      const copies = shape.families.find((f) => f.namespace === namespace && f.name === name)?.copies ?? 0
      const list = byFamily.get(k)!.sort((a, b) => a.name.localeCompare(b.name))
      return [k, { key: k, namespace, name, color, tables: list, copies }]
    }),
  )
  const familyOf = (id: string): Family | undefined => {
    const main = tables.get(placed.get(id)?.copy_of ?? id)
    return main ? families.get(famKey(main)) : undefined
  }
  // Links drawn as lines, and shared keys, which are noted instead.
  const out = new Map<string, Link[]>()
  const into = new Map<string, Link[]>()
  const sharedOut = new Map<string, Link[]>()
  const sharedIn = new Map<string, Link[]>()
  for (const l of shape.links) {
    const [o, i] = l.shared ? [sharedOut, sharedIn] : [out, into]
    if (!o.has(l.from)) o.set(l.from, [])
    o.get(l.from)!.push(l)
    if (!i.has(l.to)) i.set(l.to, [])
    i.get(l.to)!.push(l)
  }
  const copiesOf = (id: string) =>
    shape.tables.filter((p) => p.copy_of === id).map((p) => tables.get(p.table)).filter((t): t is Table => !!t)
  const views = new Map((model.views ?? []).map((v) => [v.id, v]))
  return { tables, views, namespaces, columns, typeNames, nameCount, path, placed, isCopy, families, familyOf, out, into, sharedOut, sharedIn, copiesOf }
}

export type Index = ReturnType<typeof indexOf>

/// A table's reference: `@orders`, or `@billing.orders` when another namespace has an `orders`.
export function tableRef(ix: Index, id: string): string {
  // A view is pointed at like a table, by its name.
  const t = ix.tables.get(id) ?? ix.views.get(id)
  if (!t) return `@${id}`
  return (ix.nameCount.get(t.name) ?? 0) > 1 ? `@${ix.path(t.namespace)}.${t.name}` : `@${t.name}`
}

export function reference(ix: Index, p: Pointer): string | null {
  if (!p) return null
  if (p.kind === 'table') return tableRef(ix, p.table)
  const c = ix.columns.get(p.column)
  return c ? `${tableRef(ix, p.table)}.${c.column.name}` : null
}

/// The reference with what it is, for a prompt that reads well to both of you.
export function referenceWithContext(ix: Index, model: Schema, p: Pointer): string | null {
  const r = reference(ix, p)
  if (!r || !p) return r
  if (p.kind === 'column') {
    const c = ix.columns.get(p.column)!.column
    const parts = [typeLabel(c.type, model.target, ix.typeNames), c.nullable ? 'may be empty' : 'required']
    if (c.comment) parts.push(c.comment)
    return `${r} (${parts.join(', ')})`
  }
  const t = ix.tables.get(p.table)
  if (!t) {
    const v = ix.views.get(p.table)
    return v ? `${r} (view in ${ix.path(v.namespace)}, reads ${v.reads?.length ?? 0}${v.comment ? `: ${v.comment}` : ''})` : r
  }
  return `${r} (table in ${ix.path(t.namespace)}, ${t.columns.length} columns${t.comment ? `: ${t.comment}` : ''})`
}

/// How a table is partitioned, in words: `day(happened_on)`, `RANGE (happened_on)`, or nothing.
export function partitioning(ix: Index, t: Table): string {
  const spec = t.options?.iceberg?.partition_spec
  if (spec?.length) return spec.map((p) => `${p.transform}(${ix.columns.get(p.source)?.column.name ?? '?'})`).join(', ')
  return t.options?.postgres?.partition_by ?? ''
}
