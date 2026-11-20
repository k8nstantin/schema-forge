// The server's API: the workspace's schemas, a schema's model, an object's SQL, and every change as it lands.

import type { Schema, SchemaInfo } from './model'

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
}

/// Calls `on` with every change committed while the page is open; returns the way to stop listening.
export function changes(on: (c: Change) => void): () => void {
  const source = new EventSource('/api/events')
  source.addEventListener('change', (e) => on(JSON.parse((e as MessageEvent).data)))
  return () => source.close()
}
