// Open a file or folder: browse this machine to a pg_dump or an Iceberg folder (or Spark SQL file), and read it into
// a schema. A MySQL dump is offered once its reader is built. In the look of the "1 · Home" and "2 · New schema" boards.

import { useEffect, useState } from 'react'

import { browse, importPath, schemas, type Listing } from '../api'
import type { Target } from '../model'
import { Brand } from './parts'

const TYPES: { id: Target | 'auto'; label: string }[] = [
  { id: 'auto', label: 'Tell from the file' },
  { id: 'postgres', label: 'PostgreSQL' },
  { id: 'iceberg', label: 'Iceberg' },
]

const size = (n?: number | null) => (n == null ? '' : n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(0)} KB` : `${(n / 1048576).toFixed(1)} MB`)

export function Locate({ open }: { open: (name: string) => void }) {
  const [at, setAt] = useState<string>('~')
  const [list, setList] = useState<Listing | null>(null)
  const [hidden, setHidden] = useState(false)
  const [picked, setPicked] = useState<{ path: string; dir: boolean } | null>(null)
  const [name, setName] = useState('')
  const [type, setType] = useState<Target | 'auto'>('auto')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [typed, setTyped] = useState('')
  const [taken, setTaken] = useState<string[]>([])
  const [replace, setReplace] = useState(false)
  useEffect(() => { schemas().then((l) => setTaken(l.map((x) => x.name)), () => undefined) }, [])

  useEffect(() => {
    setError(null)
    // Only the folder asked for last is shown, whatever order the answers come back in.
    let current = true
    browse(at).then(
      (l) => { if (current) { setList(l); setTyped(l.path) } },
      (e) => { if (current) setError(String(e.message ?? e)) },
    )
    return () => { current = false }
  }, [at])

  const join = (dir: string, n: string) => `${dir.replace(/\/$/, '')}/${n}`
  const pick = (path: string, dir: boolean) => {
    setPicked({ path, dir })
    const base = path.split('/').pop() ?? ''
    if (!name) setName(base.replace(/\.(sql|dump|txt)$/i, '').toLowerCase().replace(/[^a-z0-9_-]+/g, '_').replace(/^[^a-z]+/, ''))
  }
  const valid = /^[a-z][a-z0-9_-]{0,62}$/.test(name)
  const exists = taken.includes(name)
  const go = () => {
    if (!picked) return
    setBusy(true)
    setError(null)
    importPath(picked.path, name, type === 'auto' ? undefined : type, exists && replace)
      .then(() => open(name), (e) => setError(String(e.message ?? e)))
      .finally(() => setBusy(false))
  }

  return (
    <div className="d-page">
      <header className="d-bar">
        <Brand />
        <a href="#/" className="d-small">Cancel</a>
      </header>
      <main className="d-main d-main-form">
        <div className="d-col d-gap-8">
          <h1 className="d-h1 d-h1-page">Open a file or folder</h1>
          <p className="d-lead">A pg_dump, or an Iceberg folder of Spark SQL definitions (or one such file). It is read into a schema you can open, check and hand to the agent.</p>
        </div>

        <section className="d-panel">
          <form className="d-row" onSubmit={(e) => { e.preventDefault(); setAt(typed) }}>
            <label className="d-field" style={{ flex: '1 1 480px' }}>
              <span className="d-label">Folder</span>
              <input className="d-input d-input-mono" style={{ fontSize: 15 }} value={typed} onChange={(e) => setTyped(e.target.value)} />
            </label>
            <button type="submit" className="d-btn d-btn-line" style={{ alignSelf: 'flex-end' }}>Go</button>
            {list?.parent && <button type="button" className="d-btn d-btn-line" style={{ alignSelf: 'flex-end' }} onClick={() => setAt(list.parent!)}>Up</button>}
          </form>
          <label className="d-row d-gap-8 d-small d-soft"><input type="checkbox" checked={hidden} onChange={(e) => setHidden(e.target.checked)} />Show hidden files</label>
          <div className="d-files" role="listbox" aria-label="Files and folders">
            {list?.entries.filter((e) => hidden || !e.hidden).map((e) => {
              const path = join(list.path, e.name)
              const on = picked?.path === path
              return (
                <div key={e.name} role="option" aria-selected={on} className={`d-file${on ? ' d-file-on' : ''}`}>
                  <button type="button" className="d-file-name" onClick={() => pick(path, e.dir)} onDoubleClick={() => e.dir && setAt(path)}>
                    <span aria-hidden="true">{e.dir ? '▸' : '·'}</span>
                    <span className="d-mono">{e.name}{e.dir ? '/' : ''}</span>
                    <span className="d-soft d-xsmall" style={{ marginLeft: 'auto' }}>{size(e.size)}</span>
                  </button>
                  {e.dir && <button type="button" className="d-file-in" onClick={() => setAt(path)}>Open folder</button>}
                </div>
              )
            })}
            {list && list.entries.filter((e) => hidden || !e.hidden).length === 0 && <span className="d-soft d-small" style={{ padding: 12 }}>Nothing here.</span>}
          </div>
          <span className="d-soft d-xsmall">Click a file, or a folder of Iceberg definitions, to pick it. "Open folder" goes inside.</span>
        </section>

        {picked && (
          <section className="d-panel">
            <div className="d-col d-gap-4">
              <h2 className="d-h2">Read it into a schema</h2>
              <p className="d-soft" style={{ margin: 0 }}><span className="d-ref">{picked.path}</span>{picked.dir ? ' (a folder: Iceberg definitions)' : ''}</p>
            </div>
            <label className="d-field" style={{ maxWidth: 520 }}>
              <span className="d-label">Schema name</span>
              <input className="d-input d-input-mono" value={name} onChange={(e) => setName(e.target.value)} />
              <span className="d-xsmall" style={{ color: name && !valid ? 'var(--d-red)' : 'var(--d-soft)' }}>
                {name && !valid ? 'Start with a letter; then lower case letters, digits, - and _.' : exists ? `There is a schema ${name} already.` : 'A new schema of this name is made.'}
              </span>
            </label>
            {exists && (
              <label className="d-row d-gap-8 d-small"><input type="checkbox" checked={replace} onChange={(e) => setReplace(e.target.checked)} />Replace what {name} holds with what is read</label>
            )}
            <div className="d-col d-gap-10">
              <span className="d-label">Its type</span>
              <div className="d-row d-gap-8">
                {TYPES.map((t) => (
                  <button key={t.id} type="button" aria-pressed={type === t.id} onClick={() => setType(t.id)} className={`d-seg${type === t.id ? ' d-seg-on' : ''}`}>{t.label}</button>
                ))}
              </div>
            </div>
            {error && <span className="d-error">{error}</span>}
            <div className="d-row">
              <button type="button" className="d-btn" disabled={!valid || busy || (exists && !replace)} onClick={go}>{busy ? 'Reading…' : 'Read it and open the schema'}</button>
            </div>
          </section>
        )}
        {!picked && error && <span className="d-error">{error}</span>}
      </main>
    </div>
  )
}
