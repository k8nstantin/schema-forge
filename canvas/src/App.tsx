// The app: Home, and a schema seen from its perspectives (Tables, Categories, Table, Map), with what you point at
// ready to copy for the agent, and the live Activity under them.

import { Text } from '@mantine/core'
import { useHotkeys } from '@mantine/hooks'
import { notifications } from '@mantine/notifications'
import { useCallback, useEffect, useMemo, useState } from 'react'

import { schemas as fetchSchemas, catalog as fetchCatalog, changeByHand, changes, model as fetchModel, schemaRules, setEnforce, shape as fetchShape, undo, type Change } from './api'
import type { Catalog, RuleLink, Schema, SchemaInfo, SchemaRules, Shape } from './model'
import { scopeTitle } from './rules/scope'
import { Categories } from './perspectives/Categories'
import { Turns } from './components/Turns'
import { Home } from './screens/Home'
import { NewSchema } from './screens/NewSchema'
import { Locate } from './screens/Locate'
import { RulesView } from './rules/RulesView'
import { MapView } from './perspectives/MapView'
import { Tables } from './screens/Tables'
import { SchemaBar } from './screens/SchemaBar'
import { Table } from './screens/Table'
import { WorkbenchProvider, indexOf, reference, referenceWithContext, type Perspective, type Pointer } from './state'

const PERSPECTIVES: { value: Perspective; label: string }[] = [
  { value: 'tables', label: 'Tables' },
  { value: 'categories', label: 'Categories' },
  { value: 'table', label: 'Table' },
  { value: 'map', label: 'Map' },
  { value: 'rules', label: 'Rules' },
]

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
  const [loaded, setLoaded] = useState<{ name: string; model: Schema; shape: Shape; rules: SchemaRules; info: SchemaInfo | null } | null>(null)
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
    Promise.all([fetchModel(name), fetchShape(name), schemaRules(name), fetchSchemas()]).then(
      ([model, shape, rules, infos]) => {
        setLoaded({ name, model, shape, rules, info: infos.find((i) => i.name === name) ?? null })
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
    if (schema && !schema.startsWith('_')) load(schema)
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
    const inside = (outer: string, inner: string): boolean =>
      outer === inner || (catalog.rules.find((r) => r.id === outer)?.rules ?? []).some((c) => inside(c, inner))
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
        const isDestructive = why.includes('destructive') && !destructive
        const isHard = why.includes('hard rules would be broken')
        if (isDestructive || isHard) {
          const ids = [...why.matchAll(/@rule:([\w.*-]+)/g)].map((m) => m[1])
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
    const softened = Promise.all(a.soften.map(({ link, global }) => setEnforce(global ? null : schema, link.rule, link.at, 'soft')))
    softened.then(
      () => tryChange(a.ops, a.destructive).then(a.done),
      (e) => {
        notifications.show({ color: 'red', message: String(e.message ?? e) })
        a.done(false)
      },
    )
  }

  const pointed = ix && pointer ? reference(ix, pointer) : null
  // What the perspective you are on counts, in the bar's right corner, as the boards put it.
  const counts = (): string | undefined => {
    if (!current || !ix) return undefined
    const tables = (current.model.tables ?? []).filter((t) => !ix.isCopy(t.id))
    const families = ix.families.size
    if (perspective === 'tables') return `${tables.length} tables · ${tables.reduce((n, t) => n + t.columns.length, 0).toLocaleString()} columns`
    if (perspective === 'categories') return `${ix.namespaces.size} namespaces · ${families} families`
    if (perspective === 'map') return `${tables.length} tables · ${families} families · ${current.shape.links.length} links`
    if (perspective === 'rules') return `${current.rules.links.filter((l) => !l.off).length} rules linked`
    return undefined
  }
  // Home and New schema are whole screens of their own, as their boards draw them.
  if (!schema) {
    return <Home catalog={catalog} version={homeVersion} open={(n) => open({ schema: n, perspective: 'tables' })}
      newSchema={() => open({ schema: '_new', perspective: 'tables' })} rules={() => open({ schema: '_rules', perspective: 'tables' })} />
  }
  if (schema === '_new') return <NewSchema catalog={catalog} open={(n) => open({ schema: n, perspective: 'tables' })} />
  if (schema === '_open') return <Locate open={(n) => open({ schema: n, perspective: 'tables' })} />
  return (
    <div className="d-page d-shell">
      <SchemaBar name={schema} info={current?.info ?? null} on={perspective} count={counts()}
        go={(p) => go(p, p === 'table' ? pointer?.table : undefined)} />
      <div className="d-shell-body">
        {schema && error && <Text c="red" p="lg">{error}</Text>}
        {schema && !error && (!current || !catalog) && <Text c="dimmed" p="lg">Opening {schema}…</Text>}
        {schema && current && catalog && (
          <WorkbenchProvider value={{ name: schema, model: current.model, shape: current.shape, go, pointer, point, catalog, rules: current.rules, reloadRules: () => reloadRules(schema), edit }}>
            {perspective === 'tables' && <Tables />}
            {perspective === 'categories' && <Categories />}
            {perspective === 'table' && <Table id={arg} />}
            {perspective === 'map' && <MapView family={arg} />}
            {perspective === 'rules' && <RulesView arg={arg} />}
          </WorkbenchProvider>
        )}
      </div>
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
      <footer className="d-foot">
        {pointed ? (
          <span className="d-row d-gap-8">
            <span>Pointing at</span>
            <code className="d-ref">{pointed}</code>
            <button type="button" className="d-mini d-mini-on" onClick={() => copy(false)} title="Copy the reference (C)">Copy</button>
            <button type="button" className="d-mini" onClick={() => copy(true)} title="Copy it with what it is (Shift+C)">Copy with context</button>
            <button type="button" className="d-mini" onClick={() => point(null)} aria-label="Stop pointing (Esc)">×</button>
          </span>
        ) : (
          <span>Click anything, then press <span className="d-key">C</span> to copy its reference for the agent</span>
        )}
        <span className="d-row d-gap-8" style={{ marginLeft: 'auto', minWidth: 0 }}>
          {activity.filter((a) => a.schema === schema).slice(0, 1).map((a) => (
            <span key={a.sequence} className="d-ellipsis" title={a.summary ?? undefined}>{a.by === 'agent' ? 'Agent' : a.by === 'you' ? 'You' : a.by}: {a.summary ?? a.kind}</span>
          ))}
          {schema && activity.some((a) => a.schema === schema && a.kind === 'change') && (
            <button type="button" className="d-mini" title="Undo the latest design change"
              onClick={() => undo(schema).catch((e) => notifications.show({ color: 'red', message: String(e.message ?? e) }))}>Undo</button>
          )}
        </span>
      </footer>
    </div>
  )
}
