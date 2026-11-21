// The app: Home, and a schema seen from its perspectives (Tables, Categories, Table, Map), with what you point at
// ready to copy for the agent, and the live Activity under them.

import { Anchor, Badge, Kbd, Text } from '@mantine/core'
import { useHotkeys } from '@mantine/hooks'
import { notifications } from '@mantine/notifications'
import { useCallback, useEffect, useMemo, useState } from 'react'

import { Refusal, catalog as fetchCatalog, changeByHand, changes, model as fetchModel, schemaRules, setEnforce, shape as fetchShape, undo, type Change } from './api'
import type { Catalog, RuleLink, Schema, SchemaRules, Shape } from './model'
import { holdsRule } from './rules/parts'
import { scopeTitle } from './rules/scope'
import { Categories } from './perspectives/Categories'
import { Turns } from './components/Turns'
import { Home } from './perspectives/Home'
import { RulesView } from './rules/RulesView'
import { MapView } from './perspectives/MapView'
import { Tables } from './perspectives/Tables'
import { TableView } from './perspectives/TableView'
import { WorkbenchProvider, indexOf, reference, referenceWithContext, type Perspective, type Pointer } from './state'

const PERSPECTIVES: { value: Perspective; label: string }[] = [
  { value: 'tables', label: 'Tables' },
  { value: 'categories', label: 'Categories' },
  { value: 'table', label: 'Table' },
  { value: 'map', label: 'Map' },
  { value: 'rules', label: 'Rules' },
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
  const [loaded, setLoaded] = useState<{ name: string; model: Schema; shape: Shape; rules: SchemaRules } | null>(null)
  const [catalog, setCatalog] = useState<Catalog | null>(null)
  const [pointer, point] = useState<Pointer>(null)
  const [activity, setActivity] = useState<Change[]>([])
  const [homeVersion, setHomeVersion] = useState(0)
  const [error, setError] = useState<string | null>(null)
  // A change waiting for you: a yes to a destructive one, or the hard rules it breaks, to turn soft first.
  const [ask, setAsk] = useState<{
    ops: unknown[]
    why: string
    destructive: boolean
    soften: { link: RuleLink; global: boolean; title: string; where: string }[]
    done: (ok: boolean) => void
  } | null>(null)

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
    Promise.all([fetchModel(name), fetchShape(name), schemaRules(name)]).then(
      ([model, shape, rules]) => {
        setLoaded({ name, model, shape, rules })
        setError(null)
      },
      (e) => setError(String(e.message ?? e)),
    )
  }, [])

  const reloadRules = useCallback((name: string) => {
    schemaRules(name).then(
      (rules) => setLoaded((l) => (l && l.name === name ? { ...l, rules } : l)),
      (e) => notifications.show({ color: 'red', message: String(e.message ?? e) }),
    )
  }, [])

  useEffect(() => {
    fetchCatalog().then(setCatalog, (e) => setError(String(e.message ?? e)))
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
        // An approved new rule joins the catalog: read it again so its sentence shows everywhere.
        if (c.kind === 'approve_rule') fetchCatalog().then(setCatalog, () => undefined)
        if (c.schema === schema) {
          if (/_rules?$|_group$|_packs$|proposal/.test(c.kind)) reloadRules(c.schema)
          else load(c.schema)
        } else if (c.schema === '*' && schema) reloadRules(schema)
      }),
    [schema, load, reloadRules],
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
    ['5', () => go('rules')],
    ['Escape', () => point(null)],
  ])

  // The links that hold a refused rule: the rule itself, or a pack it sits in, linked here or for every schema.
  const holding = useCallback((ruleIds: string[]) => {
    if (!current || !catalog || !ix) return []
    const inside = (outer: string, inner: string) => holdsRule(catalog, outer, inner)
    const all = [...current.rules.global.map((l) => ({ link: l, global: true })), ...current.rules.links.map((l) => ({ link: l, global: false }))]
    return all
      .filter(({ link }) => !link.off && link.enforce !== 'soft' && ruleIds.some((id) => inside(link.rule, id)))
      .map(({ link, global }) => ({
        link,
        global,
        title: catalog.rules.find((r) => r.id === link.rule)?.title ?? link.rule,
        where: global ? 'every schema' : scopeTitle(ix, current.name, link.at),
      }))
  }, [current, catalog, ix])

  const tryChange = useCallback((ops: unknown[], destructive: boolean): Promise<boolean> => {
    if (!schema) return Promise.resolve(false)
    return changeByHand(schema, ops, { destructive }).then(
      (r) => {
        const said = r.summaries.join('; ')
        if (r.soft.length) notifications.show({ color: 'yellow', message: `${said}. ${r.soft.length} soft ${r.soft.length === 1 ? 'break' : 'breaks'}, highlighted.` })
        else notifications.show({ message: said, autoClose: 2200 })
        return true
      },
      (e) => {
        const why = String(e.message ?? e)
        // The server says what kind of refusal it is: a yes is wanted, or hard rules are broken.
        const kind = e instanceof Refusal ? e.kind : undefined
        const isDestructive = kind === 'destructive' && !destructive
        const isHard = kind === 'hard'
        if (isDestructive || isHard) {
          const ids = e instanceof Refusal ? e.rules : []
          return new Promise<boolean>((done) => setAsk({ ops, why, destructive: isDestructive || destructive, soften: isHard ? holding(ids) : [], done }))
        }
        notifications.show({ color: 'red', message: why })
        return false
      },
    )
  }, [schema, holding])
  const edit = useCallback((ops: unknown[]) => tryChange(ops, false), [tryChange])
  const answer = (go: boolean) => {
    if (!ask || !schema) return
    const a = ask
    setAsk(null)
    if (!go) return a.done(false)
    // Turned soft only for this change: if it still does not land, the rules are put back as they were.
    const turned: typeof a.soften = []
    const putBack = () => Promise.all(turned.map(({ link, global }) => setEnforce(global ? null : schema, link.rule, link.at, 'hard').catch(() => undefined)))
    Promise.all(a.soften.map((h) => setEnforce(h.global ? null : schema, h.link.rule, h.link.at, 'soft').then(() => { turned.push(h) })))
      .then(() => tryChange(a.ops, a.destructive))
      .then(
        (ok) => (ok ? a.done(true) : putBack().then(() => a.done(false))),
        (e) => {
          notifications.show({ color: 'red', message: `${String(e.message ?? e)}. The rules turned soft are hard again.` })
          putBack().then(() => a.done(false))
        },
      )
  }

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
        {schema && !error && (!current || !catalog) && <Text c="dimmed" p="lg">Opening {schema}…</Text>}
        {schema && current && catalog && (
          <WorkbenchProvider value={{ name: schema, model: current.model, shape: current.shape, go, pointer, point, catalog, rules: current.rules, reloadRules: () => reloadRules(schema), edit }}>
            {perspective === 'tables' && <Tables />}
            {perspective === 'categories' && <Categories />}
            {perspective === 'table' && <TableView id={arg} />}
            {perspective === 'map' && <MapView family={arg} />}
            {perspective === 'rules' && <RulesView arg={arg} />}
          </WorkbenchProvider>
        )}
      </main>
      {ask && (
        <div className="sf-ask" role="alertdialog" aria-label="Your decision">
          <span className="sf-strong">{ask.soften.length ? 'This breaks hard rules. Hard is not overridden: turn them soft to go ahead.' : ask.why.includes('hard rules') ? 'This breaks hard rules.' : 'This is destructive.'}</span>
          <span className="sf-ask-why">{ask.why}</span>
          {ask.soften.length > 0 && (
            <span className="sf-col sf-tight">
              {ask.soften.map(({ title, where, link }) => (
                <span key={`${link.rule}${where}`} className="sf-small">Turns soft: <b>{title}</b> at {where}</span>
              ))}
            </span>
          )}
          <span className="sf-row-gap">
            {ask.soften.length > 0 && <button type="button" className="sf-button" onClick={() => answer(true)}>Turn them soft and make the change</button>}
            {!ask.soften.length && !ask.why.includes('hard rules') && <button type="button" className="sf-button sf-danger" onClick={() => answer(true)}>Yes, do it</button>}
            <button type="button" className="sf-chip" onClick={() => answer(false)}>Cancel</button>
          </span>
        </div>
      )}
      {schema && current && <Turns schema={schema} onError={(m) => notifications.show({ color: 'red', message: m })} />}
      <footer className="sf-activity">
        <Text size="xs" c="dimmed" fw={600}>Activity</Text>
        {schema && activity.some((a) => a.schema === schema && a.kind === 'change') && (
          <button type="button" className="sf-chip" title="Undo the latest design change"
            onClick={() => undo(schema).catch((e) => notifications.show({ color: 'red', message: String(e.message ?? e) }))}>
            Undo
          </button>
        )}
        {activity.length === 0 ? (
          <Text size="xs" c="dimmed">Changes appear here as they land.</Text>
        ) : (
          activity.slice(0, 4).map((a) => (
            <Text key={`${a.schema}-${a.sequence}`} size="xs" className="sf-ellipsis" title={a.summary ?? undefined}>
              <Text span c="pelican.3">{a.schema}</Text> #{a.sequence} {a.kind === 'change' ? '' : `${a.kind} `}by {a.by}
              {a.summary ? `: ${a.summary}` : ''}
            </Text>
          ))
        )}
      </footer>
    </div>
  )
}
