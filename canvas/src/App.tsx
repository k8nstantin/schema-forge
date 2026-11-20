// The app: Home, and a schema seen from its perspectives, with the Inspector and the live Activity beside them.

import { Anchor, Badge, Group, Kbd, SegmentedControl, Text } from '@mantine/core'
import { useHotkeys } from '@mantine/hooks'
import { notifications } from '@mantine/notifications'
import { useCallback, useEffect, useState } from 'react'

import { changes, model as fetchModel, type Change } from './api'
import { Diagram } from './diagram/Diagram'
import type { Schema } from './model'
import { Definition } from './perspectives/Definition'
import { Home } from './perspectives/Home'
import { Inspector } from './perspectives/Inspector'
import { List } from './perspectives/List'
import { WorkbenchProvider, indexOf, reference, referenceWithContext, type Selection } from './state'

type Perspective = 'diagram' | 'list' | 'definition'
const PERSPECTIVES: { value: Perspective; label: string }[] = [
  { value: 'diagram', label: 'Diagram' },
  { value: 'list', label: 'List' },
  { value: 'definition', label: 'Definition' },
]
const TARGET = { postgres: 'PostgreSQL', mysql: 'MySQL', iceberg: 'Iceberg' } as const

/// `#/<schema>/<perspective>`: where you are survives a reload.
function readHash(): { schema: string | null; perspective: Perspective } {
  const [, schema, p] = window.location.hash.split('/')
  const perspective = PERSPECTIVES.some((x) => x.value === p) ? (p as Perspective) : 'diagram'
  return { schema: schema ? decodeURIComponent(schema) : null, perspective }
}

export default function App() {
  const [{ schema, perspective }, setPlace] = useState(readHash)
  const [model, setModel] = useState<Schema | null>(null)
  const [selection, select] = useState<Selection>(null)
  const [activity, setActivity] = useState<Change[]>([])
  const [homeVersion, setHomeVersion] = useState(0)
  const [error, setError] = useState<string | null>(null)

  const go = useCallback((s: string | null, p: Perspective = 'diagram') => {
    window.location.hash = s ? `/${encodeURIComponent(s)}/${p}` : ''
    setPlace({ schema: s, perspective: p })
    if (!s) select(null)
  }, [])

  useEffect(() => {
    const onHash = () => setPlace(readHash())
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  const load = useCallback((name: string) => {
    fetchModel(name).then(
      (m) => {
        setModel(m)
        setError(null)
      },
      (e) => setError(String(e.message ?? e)),
    )
  }, [])

  useEffect(() => {
    setModel(null)
    select(null)
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

  const copy = (withContext: boolean) => {
    if (!model || !selection) return
    const ix = indexOf(model)
    const text = withContext ? referenceWithContext(selection, ix, model) : reference(selection, ix)
    if (text) {
      navigator.clipboard.writeText(text).then(() => notifications.show({ message: `Copied ${text}`, autoClose: 1800 }))
    }
  }
  useHotkeys([
    ['c', () => copy(false)],
    ['shift+c', () => copy(true)],
    ['1', () => schema && go(schema, 'diagram')],
    ['2', () => schema && go(schema, 'list')],
    ['3', () => schema && go(schema, 'definition')],
    ['Escape', () => select(null)],
  ])

  return (
    <div className="sf-app">
      <header className="sf-header">
        <Group gap="md" wrap="nowrap">
          <Anchor className="sf-brand" onClick={() => go(null)} underline="never">
            Schema Forge
          </Anchor>
          {schema && (
            <>
              <Text c="dimmed">/</Text>
              <Text fw={600}>{schema}</Text>
              {model && <Badge variant="light">{TARGET[model.target]}</Badge>}
            </>
          )}
        </Group>
        {schema && (
          <SegmentedControl
            size="xs"
            value={perspective}
            onChange={(p) => go(schema, p as Perspective)}
            data={PERSPECTIVES}
          />
        )}
        <Group gap={6} c="dimmed" visibleFrom="md">
          <Kbd size="xs">C</Kbd>
          <Text size="xs">copy reference</Text>
          <Kbd size="xs">1</Kbd>
          <Kbd size="xs">2</Kbd>
          <Kbd size="xs">3</Kbd>
          <Text size="xs">perspectives</Text>
        </Group>
      </header>
      {!schema && (
        <main className="sf-home">
          <Home open={(n) => go(n)} version={homeVersion} />
        </main>
      )}
      {schema && error && (
        <Text c="red" p="lg">
          {error}
        </Text>
      )}
      {schema && model && (
        <WorkbenchProvider value={{ name: schema, model, selection, select }}>
          <main className="sf-body">
            <section className="sf-perspective">
              {perspective === 'diagram' && <Diagram />}
              {perspective === 'list' && <List />}
              {perspective === 'definition' && <Definition />}
            </section>
            <aside className="sf-inspector">
              <Inspector />
            </aside>
          </main>
        </WorkbenchProvider>
      )}
      <footer className="sf-activity">
        <Text size="xs" c="dimmed" fw={600}>
          Activity
        </Text>
        {activity.length === 0 ? (
          <Text size="xs" c="dimmed">
            Changes appear here as they land.
          </Text>
        ) : (
          activity.slice(0, 6).map((a) => (
            <Text key={`${a.schema}-${a.sequence}`} size="xs">
              <Text span c="pelican.3">
                {a.schema}
              </Text>{' '}
              #{a.sequence} {a.kind} by {a.by}
            </Text>
          ))
        )}
      </footer>
    </div>
  )
}
