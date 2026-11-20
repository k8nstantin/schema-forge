// The app: Home, and a schema seen from its perspectives (Tables, Categories, Table, Map), with what you point at
// ready to copy for the agent, and the live Activity under them.

import { Anchor, Badge, Kbd, Text } from '@mantine/core'
import { useHotkeys } from '@mantine/hooks'
import { notifications } from '@mantine/notifications'
import { useCallback, useEffect, useMemo, useState } from 'react'

import { changes, model as fetchModel, shape as fetchShape, type Change } from './api'
import type { Schema, Shape } from './model'
import { Categories } from './perspectives/Categories'
import { Home } from './perspectives/Home'
import { MapView } from './perspectives/MapView'
import { Tables } from './perspectives/Tables'
import { TableView } from './perspectives/TableView'
import { WorkbenchProvider, indexOf, reference, referenceWithContext, type Perspective, type Pointer } from './state'

const PERSPECTIVES: { value: Perspective; label: string }[] = [
  { value: 'tables', label: 'Tables' },
  { value: 'categories', label: 'Categories' },
  { value: 'table', label: 'Table' },
  { value: 'map', label: 'Map' },
]
const TARGET = { postgres: 'PostgreSQL', mysql: 'MySQL', iceberg: 'Iceberg' } as const

interface Place { schema: string | null; perspective: Perspective; arg?: string }

/// `#/<schema>/<perspective>/<table or family>`: where you are survives a reload and can be sent.
function readHash(): Place {
  const [, schema, p, arg] = window.location.hash.split('/')
  const perspective = PERSPECTIVES.some((x) => x.value === p) ? (p as Perspective) : 'tables'
  return { schema: schema ? decodeURIComponent(schema) : null, perspective, arg: arg ? decodeURIComponent(arg) : undefined }
}

function writeHash(p: Place) {
  window.location.hash = p.schema ? `/${encodeURIComponent(p.schema)}/${p.perspective}${p.arg ? `/${encodeURIComponent(p.arg)}` : ''}` : ''
}

export default function App() {
  const [place, setPlace] = useState(readHash)
  const { schema, perspective, arg } = place
  const [loaded, setLoaded] = useState<{ name: string; model: Schema; shape: Shape } | null>(null)
  const [pointer, point] = useState<Pointer>(null)
  const [activity, setActivity] = useState<Change[]>([])
  const [homeVersion, setHomeVersion] = useState(0)
  const [error, setError] = useState<string | null>(null)

  const open = useCallback((p: Place) => {
    writeHash(p)
    setPlace(p)
    document.querySelector('.sf-main')?.scrollTo({ top: 0 })
  }, [])

  useEffect(() => {
    const onHash = () => setPlace(readHash())
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  const load = useCallback((name: string) => {
    Promise.all([fetchModel(name), fetchShape(name)]).then(
      ([model, shape]) => {
        setLoaded({ name, model, shape })
        setError(null)
      },
      (e) => setError(String(e.message ?? e)),
    )
  }, [])

  useEffect(() => {
    point(null)
    if (schema) load(schema)
  }, [schema, load])

  // Every change, as it lands: the open schema reloads, Home recounts, Activity shows it.
  useEffect(
    () =>
      changes((c) => {
        setActivity((a) => [c, ...a].slice(0, 30))
        setHomeVersion((v) => v + 1)
        if (c.schema === schema) load(c.schema)
      }),
    [schema, load],
  )

  const current = loaded && loaded.name === schema ? loaded : null
  const ix = useMemo(() => (current ? indexOf(current.model, current.shape) : null), [current])
  const go = useCallback((p: Perspective, a?: string) => { if (schema) open({ schema, perspective: p, arg: a }) }, [schema, open])

  const copy = (withContext: boolean) => {
    if (!current || !ix || !pointer) return
    const text = withContext ? referenceWithContext(ix, current.model, pointer) : reference(ix, pointer)
    if (!text) return
    navigator.clipboard.writeText(text).then(
      () => notifications.show({ message: `Copied ${text}`, autoClose: 1800 }),
      () => notifications.show({ color: 'red', message: `Could not copy; select it: ${text}` }),
    )
  }
  useHotkeys([
    ['c', () => copy(false)],
    ['shift+c', () => copy(true)],
    ['1', () => go('tables')],
    ['2', () => go('categories')],
    ['3', () => go('table', pointer?.table)],
    ['4', () => go('map')],
    ['Escape', () => point(null)],
  ])

  const pointed = ix && pointer ? reference(ix, pointer) : null
  return (
    <div className="sf-app">
      <header className="sf-header">
        <div className="sf-head-left">
          <Anchor className="sf-brand" onClick={() => open({ schema: null, perspective: 'tables' })} underline="never">
            Schema Forge
          </Anchor>
          {schema && (
            <div className="sf-schemaname">
              <span className="sf-caption">schema</span>
              <span className="sf-schema-title">{schema}</span>
              {current && <Badge variant="light">{TARGET[current.model.target]}</Badge>}
            </div>
          )}
        </div>
        {schema && (
          <nav className="sf-perspectives" role="tablist" aria-label="Perspectives">
            {PERSPECTIVES.map((p, i) => (
              <button key={p.value} type="button" role="tab" aria-selected={perspective === p.value} title={`${p.label} (${i + 1})`}
                onClick={() => go(p.value, p.value === 'table' ? pointer?.table : undefined)}>
                {p.label}
              </button>
            ))}
          </nav>
        )}
        <div className="sf-pointer">
          {pointed ? (
            <>
              <span className="sf-caption">pointing at</span>
              <code className="sf-ref">{pointed}</code>
              <button type="button" className="sf-chip" onClick={() => copy(false)} title="Copy the reference (C)">Copy</button>
              <button type="button" className="sf-chip" onClick={() => copy(true)} title="Copy it with what it is (Shift+C)">Copy with context</button>
              <button type="button" className="sf-chip" onClick={() => point(null)} title="Stop pointing (Esc)" aria-label="Stop pointing">×</button>
            </>
          ) : (
            schema && <span className="sf-muted sf-small">Click a table's title or a column to point at it; <Kbd size="xs">C</Kbd> copies it for your agent.</span>
          )}
        </div>
      </header>
      <main className="sf-main">
        {!schema && <Home open={(n) => open({ schema: n, perspective: 'tables' })} version={homeVersion} />}
        {schema && error && <Text c="red" p="lg">{error}</Text>}
        {schema && !error && !current && <Text c="dimmed" p="lg">Opening {schema}…</Text>}
        {schema && current && (
          <WorkbenchProvider value={{ name: schema, model: current.model, shape: current.shape, go, pointer, point }}>
            {perspective === 'tables' && <Tables />}
            {perspective === 'categories' && <Categories />}
            {perspective === 'table' && <TableView id={arg} />}
            {perspective === 'map' && <MapView family={arg} />}
          </WorkbenchProvider>
        )}
      </main>
      <footer className="sf-activity">
        <Text size="xs" c="dimmed" fw={600}>Activity</Text>
        {activity.length === 0 ? (
          <Text size="xs" c="dimmed">Changes appear here as they land.</Text>
        ) : (
          activity.slice(0, 6).map((a) => (
            <Text key={`${a.schema}-${a.sequence}`} size="xs">
              <Text span c="pelican.3">{a.schema}</Text> #{a.sequence} {a.kind} by {a.by}
            </Text>
          ))
        )}
      </footer>
    </div>
  )
}
