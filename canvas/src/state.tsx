// What every perspective shares: the open schema, its model, and the selection, which is the same object in
// every perspective and is what a reference (`@orders.total`) points at.

import { createContext, useContext, useMemo, type ReactNode } from 'react'

import { typeLabel, type Column, type Schema, type Table, type View } from './model'

export type Selection =
  | { kind: 'table'; id: string }
  | { kind: 'view'; id: string }
  | { kind: 'column'; id: string; table: string }
  | null

export interface Workbench {
  name: string
  model: Schema
  selection: Selection
  select: (s: Selection) => void
}

const Context = createContext<Workbench | null>(null)

export function WorkbenchProvider({ value, children }: { value: Workbench; children: ReactNode }) {
  return <Context.Provider value={value}>{children}</Context.Provider>
}

export function useWorkbench(): Workbench {
  const w = useContext(Context)
  if (!w) throw new Error('outside a schema')
  return w
}

/// Lookups over the model, made once per model.
export function useIndex() {
  const { model } = useWorkbench()
  return useMemo(() => indexOf(model), [model])
}

export function indexOf(model: Schema) {
  const tables = new Map<string, Table>((model.tables ?? []).map((t) => [t.id, t]))
  const views = new Map<string, View>((model.views ?? []).map((v) => [v.id, v]))
  const namespaces = new Map((model.namespaces ?? []).map((n) => [n.id, n]))
  const columns = new Map<string, { table: Table; column: Column }>()
  for (const t of model.tables ?? []) for (const c of t.columns) columns.set(c.id, { table: t, column: c })
  const typeNames = new Map((model.types ?? []).map((t) => [t.id, t.name]))
  // A name is unique unless another namespace has it too; then references carry the namespace.
  const nameCount = new Map<string, number>()
  for (const o of [...(model.tables ?? []), ...(model.views ?? [])]) nameCount.set(o.name, (nameCount.get(o.name) ?? 0) + 1)
  const path = (namespace: string): string => {
    const n = namespaces.get(namespace)
    if (!n) return ''
    return n.parent ? `${path(n.parent)}.${n.name}` : n.name
  }
  return { tables, views, namespaces, columns, typeNames, nameCount, path }
}

type Index = ReturnType<typeof indexOf>

/// The reference to the selection: `@orders`, `@billing.orders` when the name is not unique, `@orders.total`.
export function reference(sel: Selection, ix: Index): string | null {
  if (!sel) return null
  const relation = (id: string) => {
    const o = ix.tables.get(id) ?? ix.views.get(id)
    if (!o) return null
    return (ix.nameCount.get(o.name) ?? 0) > 1 ? `${ix.path(o.namespace)}.${o.name}` : o.name
  }
  if (sel.kind === 'column') {
    const c = ix.columns.get(sel.id)
    const r = relation(sel.table)
    return c && r ? `@${r}.${c.column.name}` : null
  }
  const r = relation(sel.id)
  return r ? `@${r}` : null
}

/// The reference with one line about it, for a prompt that reads well to both of you.
export function referenceWithContext(sel: Selection, ix: Index, model: Schema): string | null {
  const r = reference(sel, ix)
  if (!r || !sel) return r
  if (sel.kind === 'column') {
    const c = ix.columns.get(sel.id)!.column
    const parts = [typeLabel(c.type, model.target, ix.typeNames), c.nullable ? 'nullable' : 'not null']
    if (c.comment) parts.push(c.comment)
    return `${r} (${parts.join(', ')})`
  }
  if (sel.kind === 'table') {
    const t = ix.tables.get(sel.id)!
    return `${r} (table, ${t.columns.length} columns${t.comment ? `: ${t.comment}` : ''})`
  }
  const v = ix.views.get(sel.id)!
  return `${r} (view${v.comment ? `: ${v.comment}` : ''})`
}
