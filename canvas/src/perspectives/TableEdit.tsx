// Editing a table by hand: the same operations the agent makes, checked by the same rules, undone the same way.
// Each section saves on its own; a destructive change asks for a yes, and a hard rule it breaks is shown, to be
// turned soft before it can go ahead.

import { useEffect, useState } from 'react'

import { typeLabel, type Table } from '../model'
import { useWorkbench } from '../state'

const TRANSFORMS = ['identity', 'year', 'month', 'day', 'hour', 'bucket[16]', 'truncate[10]']

export function TableEdit({ t }: { t: Table }) {
  const { model, ix, edit, go } = useWorkbench()
  const iceberg = model.target === 'iceberg'
  const [name, setName] = useState(t.name)
  const [about, setAbout] = useState(t.comment ?? '')
  // Reset to what the table is only when that changes: a reload with the same values keeps what you typed.
  useEffect(() => { setName(t.name); setAbout(t.comment ?? '') }, [t.name, t.comment])
  const key = new Set(iceberg ? t.options?.iceberg?.identifier_fields ?? [] : t.primary_key?.columns ?? [])
  const rels = (model.relationships ?? []).filter((r) => r.from.table === t.id)
  const label = (id: string) => ix.columns.get(id)?.column.name ?? id
  return (
    <div className="sf-col sf-gap-l">
      <section className="sf-edit-section">
        <span className="sf-caption">Name and description</span>
        <span className="sf-editbar">
          <input className="sf-edit-input sf-edit-title" value={name} onChange={(e) => setName(e.target.value)} aria-label="Table name" />
          <button type="button" className="sf-chip" disabled={!name.trim() || name === t.name} onClick={() => edit([{ op: 'rename_table', table: t.id, name: name.trim() }])}>Rename</button>
        </span>
        <span className="sf-editbar">
          <input className="sf-edit-input sf-flex1" value={about} onChange={(e) => setAbout(e.target.value)} placeholder="What one row of it is" aria-label="Description" />
          <button type="button" className="sf-chip" disabled={about === (t.comment ?? '')} onClick={() => edit([{ op: 'set_table_comment', table: t.id, comment: about }])}>Save the description</button>
        </span>
      </section>

      <section className="sf-edit-section">
        <span className="sf-caption">Columns · {iceberg ? 'key = identifier fields' : 'key = primary key'}</span>
        <div className="sf-editrow sf-thead"><span>Column</span><span>Type</span><span>Not null</span><span>Key</span><span>Description</span><span></span></div>
        {t.columns.map((c) => <ColumnRow key={c.id} table={t} id={c.id} inKey={key.has(c.id)} keyCols={[...key]} />)}
        <NewColumn t={t} />
      </section>

      <section className="sf-edit-section">
        <span className="sf-caption">Links: what its columns point at</span>
        {rels.length === 0 && <span className="sf-muted sf-small">None yet.</span>}
        {rels.map((r) => (
          <span key={r.id} className="sf-row-between">
            <span className="sf-mono sf-small">{r.from.columns.map(label).join(', ')} → {ix.tables.get(r.to.table)?.name}.{r.to.columns.map(label).join(', ')}</span>
            <button type="button" className="sf-chip" onClick={() => edit([{ op: 'unrelate', relationship: r.id }])}>Unlink</button>
          </span>
        ))}
        <NewLink t={t} />
      </section>

      {iceberg ? <IcebergEdit t={t} /> : <Indexes t={t} />}

      <section className="sf-edit-section">
        <span className="sf-caption">Drop it</span>
        <span className="sf-editbar">
          <span className="sf-muted sf-small">The table and its links go; views that read it keep it from being dropped. You will be asked.</span>
          <button type="button" className="sf-chip sf-danger-chip" onClick={() => edit([{ op: 'drop_table', table: t.id }]).then((ok) => ok && go('tables'))}>Drop {t.name}</button>
        </span>
      </section>
    </div>
  )
}

function ColumnRow({ table, id, inKey, keyCols }: { table: Table; id: string; inKey: boolean; keyCols: string[] }) {
  const { model, ix, edit } = useWorkbench()
  const c = table.columns.find((x) => x.id === id)!
  const shown = typeLabel(c.type, model.target, ix.typeNames)
  const editable = c.type.name !== 'struct' && !(c.type.of?.name === 'struct') && c.type.name !== 'verbatim'
  const [name, setName] = useState(c.name)
  const [type, setType] = useState(shown)
  const [required, setRequired] = useState(!c.nullable)
  const [about, setAbout] = useState(c.comment ?? '')
  useEffect(() => { setName(c.name); setType(shown); setRequired(!c.nullable); setAbout(c.comment ?? '') }, [c.name, shown, c.nullable, c.comment])
  const dirty = name !== c.name || type !== shown || required !== !c.nullable || about !== (c.comment ?? '')
  const save = () => {
    const ops: unknown[] = []
    const alter: Record<string, unknown> = { op: 'alter_column', column: id }
    if (type !== shown) alter.type = type
    if (required !== !c.nullable) alter.nullable = !required
    if (about !== (c.comment ?? '')) alter.comment = about
    if (Object.keys(alter).length > 2) ops.push(alter)
    if (name !== c.name) ops.push({ op: 'rename_column', column: id, name })
    if (ops.length) edit(ops)
  }
  const toggleKey = () => {
    const next = inKey ? keyCols.filter((k) => k !== id) : [...keyCols, id]
    edit([{ op: 'set_primary_key', table: table.id, columns: next }])
  }
  return (
    <div className={`sf-editrow${dirty ? ' sf-dirty' : ''}`}>
      <input className="sf-edit-input sf-mono" value={name} onChange={(e) => setName(e.target.value)} aria-label="Column name" />
      <input className="sf-edit-input sf-mono" value={type} onChange={(e) => setType(e.target.value)} disabled={!editable} title={editable ? 'As the target writes it' : 'A nested type: ask the agent'} aria-label="Type" />
      <input type="checkbox" checked={required} onChange={(e) => setRequired(e.target.checked)} aria-label="Not null" />
      <input type="checkbox" checked={inKey} onChange={toggleKey} aria-label="In the key" />
      <input className="sf-edit-input" value={about} onChange={(e) => setAbout(e.target.value)} placeholder="What it holds" aria-label="Description" />
      <span className="sf-row-gap">
        {dirty ? <button type="button" className="sf-chip sf-on" onClick={save}>Save</button> : null}
        <button type="button" className="sf-chip" title="Drop the column" aria-label={`Drop ${c.name}`} onClick={() => edit([{ op: 'drop_column', column: id }])}>×</button>
      </span>
    </div>
  )
}

function NewColumn({ t }: { t: Table }) {
  const { model, edit } = useWorkbench()
  const blank = { name: '', type: model.target === 'iceberg' ? 'string' : 'text', required: false, about: '' }
  const [c, setC] = useState(blank)
  const add = () => {
    edit([{ op: 'add_column', table: t.id, column: { name: c.name.trim(), type: c.type, nullable: !c.required, comment: c.about || undefined } }]).then((ok) => ok && setC(blank))
  }
  return (
    <div className="sf-editrow sf-new">
      <input className="sf-edit-input sf-mono" value={c.name} onChange={(e) => setC({ ...c, name: e.target.value })} placeholder="new column" aria-label="New column name" />
      <input className="sf-edit-input sf-mono" value={c.type} onChange={(e) => setC({ ...c, type: e.target.value })} aria-label="New column type" />
      <input type="checkbox" checked={c.required} onChange={(e) => setC({ ...c, required: e.target.checked })} aria-label="New column required" />
      <span />
      <input className="sf-edit-input" value={c.about} onChange={(e) => setC({ ...c, about: e.target.value })} placeholder="What it holds" aria-label="New column description" />
      <button type="button" className="sf-chip sf-on" disabled={!c.name.trim() || !c.type.trim()} onClick={add}>Add</button>
    </div>
  )
}

function NewLink({ t }: { t: Table }) {
  const { model, ix, edit } = useWorkbench()
  const [col, setCol] = useState('')
  const [to, setTo] = useState('')
  const [toCol, setToCol] = useState('')
  const target = to ? ix.tables.get(to) : undefined
  const tables = (model.tables ?? []).filter((x) => !ix.isCopy(x.id)).sort((a, b) => a.name.localeCompare(b.name))
  return (
    <span className="sf-editbar">
      <select className="sf-edit-input" value={col} onChange={(e) => setCol(e.target.value)} aria-label="Its column">
        <option value="">its column…</option>
        {t.columns.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
      </select>
      <span className="sf-muted">→</span>
      <select className="sf-edit-input" value={to} onChange={(e) => { setTo(e.target.value); setToCol('') }} aria-label="The table it points at">
        <option value="">table…</option>
        {tables.map((x) => <option key={x.id} value={x.id}>{ix.path(x.namespace)}.{x.name}</option>)}
      </select>
      <select className="sf-edit-input" value={toCol} onChange={(e) => setToCol(e.target.value)} disabled={!target} aria-label="Its column">
        <option value="">column…</option>
        {target?.columns.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
      </select>
      <button type="button" className="sf-chip sf-on" disabled={!col || !to || !toCol}
        onClick={() => edit([{ op: 'relate', from: t.id, columns: [col], to, to_columns: [toCol] }]).then((ok) => ok && (setCol(''), setTo(''), setToCol('')))}>
        Link
      </button>
    </span>
  )
}

function Indexes({ t }: { t: Table }) {
  const { ix, edit } = useWorkbench()
  const [cols, setCols] = useState<string[]>([])
  const [unique, setUnique] = useState(false)
  return (
    <section className="sf-edit-section">
      <span className="sf-caption">Indexes</span>
      {(t.indexes ?? []).length === 0 && <span className="sf-muted sf-small">None.</span>}
      {(t.indexes ?? []).map((i) => (
        <span key={i.id} className="sf-row-between">
          <span className="sf-mono sf-small">{i.name}{i.unique ? ' (unique)' : ''}: {i.parts.map((p) => (p.column ? ix.columns.get(p.column)?.column.name : p.expression)).join(', ')}</span>
          <button type="button" className="sf-chip" onClick={() => edit([{ op: 'drop_index', table: t.id, index: i.id }])}>Drop</button>
        </span>
      ))}
      <span className="sf-editbar">
        <select className="sf-edit-input" value="" onChange={(e) => e.target.value && setCols([...cols, e.target.value])} aria-label="Add a column to the index">
          <option value="">{cols.length ? 'and…' : 'index on…'}</option>
          {t.columns.filter((c) => !cols.includes(c.id)).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
        <span className="sf-mono sf-small">{cols.map((c) => ix.columns.get(c)?.column.name).join(', ')}</span>
        <label className="sf-check"><input type="checkbox" checked={unique} onChange={(e) => setUnique(e.target.checked)} /> unique</label>
        <button type="button" className="sf-chip sf-on" disabled={!cols.length}
          onClick={() => edit([{ op: 'add_index', table: t.id, columns: cols.map((c) => ix.columns.get(c)?.column.name ?? c), unique }]).then((ok) => ok && (setCols([]), setUnique(false)))}>Add the index</button>
        {cols.length > 0 && <button type="button" className="sf-chip" onClick={() => setCols([])}>Clear</button>}
      </span>
    </section>
  )
}

function IcebergEdit({ t }: { t: Table }) {
  const { ix, edit } = useWorkbench()
  const ice = t.options?.iceberg
  const spec = ice?.partition_spec ?? []
  const [col, setCol] = useState('')
  const [transform, setTransform] = useState('day')
  const [k, setK] = useState('')
  const [v, setV] = useState('')
  // The spec as it is, each field by its column's name and with its own name, so a field added or taken away
  // leaves the others as they were.
  const fields = (list: { source: string; transform: string; name?: string }[]) =>
    list.map((p) => ({ column: ix.columns.get(p.source)?.column.name ?? p.source, transform: p.transform, name: p.name }))
  const props = Object.entries(ice?.properties ?? {})
  const mor = ['write.delete.mode', 'write.update.mode', 'write.merge.mode']
  const isMor = mor.every((m) => ice?.properties?.[m] === 'merge-on-read')
  return (
    <>
      <section className="sf-edit-section">
        <span className="sf-caption">Partitioned by</span>
        {spec.length === 0 && <span className="sf-muted sf-small">Not partitioned.</span>}
        {spec.map((p, i) => (
          <span key={i} className="sf-row-between">
            <span className="sf-mono sf-small">{p.transform}({ix.columns.get(p.source)?.column.name})</span>
            <button type="button" className="sf-chip" onClick={() => edit([{ op: 'set_partition_spec', table: t.id, fields: fields(spec.filter((_, j) => j !== i)) }])}>Take away</button>
          </span>
        ))}
        <span className="sf-editbar">
          <select className="sf-edit-input" value={transform} onChange={(e) => setTransform(e.target.value)} aria-label="Transform">
            {TRANSFORMS.map((x) => <option key={x} value={x}>{x}</option>)}
          </select>
          <select className="sf-edit-input" value={col} onChange={(e) => setCol(e.target.value)} aria-label="Column">
            <option value="">of column…</option>
            {t.columns.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
          <button type="button" className="sf-chip sf-on" disabled={!col}
            onClick={() => edit([{ op: 'set_partition_spec', table: t.id, fields: [...fields(spec), { column: col, transform }] }]).then((ok) => ok && setCol(''))}>Add</button>
        </span>
      </section>
      <section className="sf-edit-section">
        <span className="sf-row-between">
          <span className="sf-caption">Properties</span>
          <button type="button" className="sf-chip" disabled={isMor} onClick={() => edit(mor.map((m) => ({ op: 'set_property', table: t.id, key: m, value: 'merge-on-read' })))}>
            {isMor ? 'Merge-on-read' : 'Make it merge-on-read'}
          </button>
        </span>
        {props.map(([key, value]) => (
          <span key={key} className="sf-row-between">
            <span className="sf-mono sf-small">{key} = {value}</span>
            <button type="button" className="sf-chip" onClick={() => edit([{ op: 'unset_property', table: t.id, key }])}>Take away</button>
          </span>
        ))}
        <span className="sf-editbar">
          <input className="sf-edit-input sf-mono" value={k} onChange={(e) => setK(e.target.value)} placeholder="write.format.default" aria-label="Property" />
          <input className="sf-edit-input sf-mono" value={v} onChange={(e) => setV(e.target.value)} placeholder="parquet" aria-label="Value" />
          <button type="button" className="sf-chip sf-on" disabled={!k.trim()} onClick={() => edit([{ op: 'set_property', table: t.id, key: k.trim(), value: v }]).then((ok) => ok && (setK(''), setV('')))}>Set</button>
        </span>
      </section>
    </>
  )
}
