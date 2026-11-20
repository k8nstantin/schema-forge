// The server's API: the workspace's schemas, a schema's model, an object's SQL, and every change as it lands.

import type { Catalog, Enforce, Proposal, Report, RuleGroup, RuleLink, Schema, SchemaInfo, SchemaRules, Scope, Shape, Verdict } from './model'

async function json<T>(path: string): Promise<T> {
  const r = await fetch(path)
  if (!r.ok) {
    const body = await r.json().catch(() => ({ error: r.statusText }))
    throw new Error(body.error ?? r.statusText)
  }
  return r.json() as Promise<T>
}

export const schemas = () => json<SchemaInfo[]>('/api/schemas')
export const model = (name: string) => json<Schema>(`/api/schemas/${encodeURIComponent(name)}`)
export const shape = (name: string) => json<Shape>(`/api/schemas/${encodeURIComponent(name)}/shape`)

export async function definition(name: string, id: string): Promise<string> {
  const r = await fetch(`/api/schemas/${encodeURIComponent(name)}/definition/${encodeURIComponent(id)}`)
  if (!r.ok) throw new Error((await r.json().catch(() => ({ error: r.statusText }))).error)
  return r.text()
}

export interface Change {
  schema: string
  sequence: number
  kind: string
  by: string
  /// For a design change or its undo: what each operation did.
  summary?: string | null
}

/// Calls `on` with every change committed while the page is open; returns the way to stop listening.
export function changes(on: (c: Change) => void): () => void {
  const source = new EventSource('/api/events')
  source.addEventListener('change', (e) => on(JSON.parse((e as MessageEvent).data)))
  return () => source.close()
}

async function send<T>(method: string, path: string, body?: unknown): Promise<T> {
  const r = await fetch(path, { method, headers: { 'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) })
  if (!r.ok) {
    const b = await r.json().catch(() => ({ error: r.statusText }))
    throw new Error(b.error ?? r.statusText)
  }
  return r.json() as Promise<T>
}

const rulesOf = (name: string) => `/api/schemas/${encodeURIComponent(name)}/rules`
export const catalog = () => json<Catalog>('/api/rules')
export const schemaRules = (name: string) => json<SchemaRules>(rulesOf(name))
export const preview = (name: string, links: RuleLink[]) => send<Report>('POST', `${rulesOf(name)}/preview`, links)
export const linkRule = (name: string | null, link: RuleLink) =>
  send('POST', name === null ? '/api/rules/global/links' : `${rulesOf(name)}/links`, link)
export const unlinkRule = (name: string | null, rule: string, at: Scope) =>
  send('POST', name === null ? '/api/rules/global/unlink' : `${rulesOf(name)}/unlink`, { rule, at })
export const setGroup = (name: string, group: RuleGroup) => send('PUT', `${rulesOf(name)}/groups`, group)
export const removeGroup = (name: string, group: string) => send('DELETE', `${rulesOf(name)}/groups/${encodeURIComponent(group)}`)
export const applyGoal = (name: string, goal: string) => send('POST', `/api/schemas/${encodeURIComponent(name)}/goals/${encodeURIComponent(goal)}`)
export const setEnforce = (name: string | null, rule: string, at: Scope, enforce: Enforce) =>
  send('POST', name === null ? '/api/rules/global/enforce' : `${rulesOf(name)}/enforce`, { rule, at, enforce })

const proposalsOf = (name: string) => `/api/schemas/${encodeURIComponent(name)}/proposals`
export const proposals = (name: string) => json<{ proposal: Proposal; verdict: Verdict | null }[]>(proposalsOf(name))
export const approve = (name: string, id: number) => send<Proposal>('POST', `${proposalsOf(name)}/${id}/approve`)
export const reject = (name: string, id: number) => send<Proposal>('POST', `${proposalsOf(name)}/${id}/reject`)
export const proposalEnforce = (name: string, id: number, enforce: Enforce) =>
  send<Proposal>('POST', `${proposalsOf(name)}/${id}/enforce`, { enforce })
export const undo = (name: string) => send('POST', `/api/schemas/${encodeURIComponent(name)}/undo`)
