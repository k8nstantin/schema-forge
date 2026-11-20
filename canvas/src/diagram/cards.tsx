// The diagram's cards: a table shows what it is at a glance, and more as you zoom in. A card keeps its size and its
// rows their places at every zoom (see geometry.ts), so edges always meet the row they belong to.

import { Handle, Position, useStore, type NodeProps } from '@xyflow/react'
import { Badge, Group, Text, Tooltip } from '@mantine/core'
import {
  IconArrowDown,
  IconArrowUp,
  IconChevronDown,
  IconChevronRight,
  IconFingerprint,
  IconKey,
  IconLayoutGrid,
  IconLink,
  IconTable,
  IconEye,
} from '@tabler/icons-react'
import { createContext, useContext, type MouseEvent } from 'react'

import { nested, typeLabel, type Column, type StructField, type Table } from '../model'
import { useIndex, useWorkbench } from '../state'
import { HEAD_PORT, columnPort, tableBadges } from './geometry'

/// Which columns show their nested fields, and how to fold or unfold one.
export const Folding = createContext<{ unfolded: Set<string>; toggle: (id: string) => void }>({
  unfolded: new Set(),
  toggle: () => {},
})

/// How much a card shows, from how far you are zoomed out.
function useDetail(): 'name' | 'keys' | 'full' {
  const zoom = useStore((s) => s.transform[2])
  return zoom < 0.4 ? 'name' : zoom < 0.75 ? 'keys' : 'full'
}

/// A size in screen pixels, whatever the zoom: names stay readable from far out.
function useScreenSize(px: number, max: number): number {
  const zoom = useStore((s) => s.transform[2])
  return Math.min(max, px / zoom)
}

/// A name that wraps only after its underscores, never inside a word.
function Breakable({ name }: { name: string }) {
  const parts = name.split(/(?<=_)/)
  return (
    <>
      {parts.map((p, i) => (
        <span key={i}>
          {p}
          {i < parts.length - 1 && <wbr />}
        </span>
      ))}
    </>
  )
}

const handle = { opacity: 0, width: 6, height: 6, minWidth: 0, minHeight: 0, border: 0 }

export function TableCard({ id, height }: NodeProps) {
  const { model, selection, select } = useWorkbench()
  const ix = useIndex()
  const folding = useContext(Folding)
  const detail = useDetail()
  // Two lines of name and a line of badges fit the card, however short it is.
  const farName = useScreenSize(13, Math.min(120, (height ?? 200) / 4))
  const t = ix.tables.get(id)
  if (!t) return null
  const selected = selection?.kind === 'table' && selection.id === id
  const roles = columnRoles(t, model.relationships ?? [])
  const badges = tableBadges(t)
  // Every column can be an end of a relationship: its handles sit on its row's ports, at every zoom.
  const handles = (
    <>
      <Handle type="target" position={Position.Left} id="relation:in" style={{ ...handle, top: HEAD_PORT }} />
      <Handle type="source" position={Position.Right} id="relation:out" style={{ ...handle, top: HEAD_PORT }} />
      {t.columns.map((c, i) => {
        const top = columnPort(t, i, folding.unfolded)
        return (
          <span key={c.id}>
            <Handle type="target" position={Position.Left} id={`${c.id}:in`} style={{ ...handle, top }} />
            <Handle type="source" position={Position.Right} id={`${c.id}:out`} style={{ ...handle, top }} />
          </span>
        )
      })}
    </>
  )
  if (detail === 'name') {
    return (
      <div
        className={`sf-card sf-far${selected ? ' sf-selected' : ''}`}
        onClick={(e) => {
          e.stopPropagation()
          select({ kind: 'table', id })
        }}
      >
        {handles}
        <div className="sf-far-name" style={{ fontSize: farName }}>
          <Breakable name={t.name} />
        </div>
        {badges.length > 0 && (
          <div className="sf-far-badges" style={{ fontSize: farName * 0.55 }}>
            {badges.map((b) => b.label).join(' · ')}
          </div>
        )}
      </div>
    )
  }
  return (
    <div
      className={`sf-card${selected ? ' sf-selected' : ''}`}
      onClick={(e) => {
        e.stopPropagation()
        select({ kind: 'table', id })
      }}
    >
      {handles}
      <div className="sf-card-head">
        <IconTable size={16} className="sf-muted" />
        <div style={{ minWidth: 0 }}>
          <Text className="sf-card-name" truncate>
            {t.name}
          </Text>
          <Text size="xs" c="dimmed" truncate>
            {ix.path(t.namespace)}
            {t.partition_of ? ` · partition of ${ix.tables.get(t.partition_of.parent)?.name}` : ''}
          </Text>
        </div>
      </div>
      {badges.length > 0 && (
        <Group gap={4} className="sf-badges" wrap="nowrap">
          {badges.map((b) => (
            <Tooltip key={b.label} label={b.tip} withArrow openDelay={300} multiline maw={360}>
              <Badge size="xs" variant={b.strong ? 'filled' : 'light'} radius="sm">
                {b.label}
              </Badge>
            </Tooltip>
          ))}
        </Group>
      )}
      <div className="sf-rows">
        {t.columns.map((c) => (
          <ColumnRow
            key={c.id}
            table={t}
            column={c}
            roles={roles.get(c.id) ?? new Set()}
            folding={folding}
            ghost={detail === 'keys' && !roles.get(c.id)?.size}
          />
        ))}
        {t.columns.length === 0 && t.partition_of && (
          <div className="sf-row sf-faint">
            <span className="sf-icons" />
            columns of {ix.tables.get(t.partition_of.parent)?.name}
          </div>
        )}
      </div>
    </div>
  )
}

type Role = 'pk' | 'unique' | 'fk' | 'identifier' | 'partition' | 'sort-asc' | 'sort-desc'

function columnRoles(t: Table, relationships: { from: { table: string; columns: string[] } }[]): Map<string, Set<Role>> {
  const roles = new Map<string, Set<Role>>()
  const add = (id: string, r: Role) => {
    if (!roles.has(id)) roles.set(id, new Set())
    roles.get(id)!.add(r)
  }
  t.primary_key?.columns.forEach((c) => add(c, 'pk'))
  t.uniques?.forEach((u) => u.columns.forEach((c) => add(c, 'unique')))
  relationships.filter((r) => r.from.table === t.id).forEach((r) => r.from.columns.forEach((c) => add(c, 'fk')))
  const ice = t.options?.iceberg
  ice?.identifier_fields?.forEach((c) => add(c, 'identifier'))
  ice?.partition_spec?.forEach((p) => add(p.source, 'partition'))
  ice?.sort_order?.forEach((s) => add(s.source, s.direction === 'desc' ? 'sort-desc' : 'sort-asc'))
  return roles
}

function ColumnRow({
  table,
  column: c,
  roles,
  folding,
  ghost,
}: {
  table: Table
  column: Column
  roles: Set<Role>
  folding: { unfolded: Set<string>; toggle: (id: string) => void }
  /// Zoomed out to keys: a column that is not one keeps its place as a faint bar.
  ghost: boolean
}) {
  const { model, selection, select } = useWorkbench()
  const ix = useIndex()
  const fields = nested(c.type)
  const open = folding.unfolded.has(c.id)
  if (ghost) {
    return (
      <>
        {[c.id, ...(open ? fields.map((f) => `${c.id}#${f.field_id}`) : [])].map((k) => (
          <div key={k} className="sf-row">
            <span className="sf-ghost" />
          </div>
        ))}
      </>
    )
  }
  const selected = selection?.kind === 'column' && selection.id === c.id
  const transforms = table.options?.iceberg?.partition_spec?.filter((p) => p.source === c.id).map((p) => p.transform)
  return (
    <>
      <div
        className={`sf-row${selected ? ' sf-selected-row' : ''}`}
        title={c.comment}
        onClick={(e) => {
          e.stopPropagation()
          select({ kind: 'column', id: c.id, table: table.id })
        }}
      >
        <span className="sf-icons">
          {roles.has('pk') && <IconKey size={13} className="sf-pk" />}
          {roles.has('identifier') && <IconFingerprint size={13} className="sf-pk" />}
          {roles.has('unique') && !roles.has('pk') && <IconKey size={13} className="sf-unique" />}
          {roles.has('fk') && <IconLink size={13} className="sf-fk" />}
        </span>
        {fields.length > 0 ? (
          <span
            className="sf-fold"
            onClick={(e) => {
              e.stopPropagation()
              folding.toggle(c.id)
            }}
          >
            {open ? <IconChevronDown size={12} /> : <IconChevronRight size={12} />}
          </span>
        ) : (
          // Names line up whether or not their column folds.
          table.columns.some((x) => nested(x.type).length > 0) && <span className="sf-fold" />
        )}
        <span className="sf-col-name">{c.name}</span>
        {c.nullable && <span className="sf-nullable" title="nullable" />}
        <span className="sf-col-cues">
          {transforms?.map((tr) => (
            <span key={tr} className="sf-cue" title={`partitioned by ${tr}`}>
              <IconLayoutGrid size={11} /> {tr}
            </span>
          ))}
          {roles.has('sort-asc') && <IconArrowUp size={12} className="sf-cue" />}
          {roles.has('sort-desc') && <IconArrowDown size={12} className="sf-cue" />}
        </span>
        <span className="sf-col-type">{typeLabel(c.type, model.target, ix.typeNames)}</span>
      </div>
      {open && fields.map((f) => <FieldRow key={f.field_id} field={f} depth={1} />)}
    </>
  )
}

function FieldRow({ field: f, depth }: { field: StructField; depth: number }) {
  const { model } = useWorkbench()
  const ix = useIndex()
  return (
    <div className="sf-row sf-field" style={{ paddingLeft: 22 + depth * 14 }} title={f.comment}>
      <span className="sf-col-name">{f.name}</span>
      {f.nullable && <span className="sf-nullable" title="nullable" />}
      <span className="sf-col-type">
        {typeLabel(f.type, model.target, ix.typeNames)} <span className="sf-faint">#{f.field_id}</span>
      </span>
    </div>
  )
}

export function ViewCard({ id, height }: NodeProps) {
  const { selection, select } = useWorkbench()
  const ix = useIndex()
  const detail = useDetail()
  // Two lines of name and a line of badges fit the card, however short it is.
  const farName = useScreenSize(13, Math.min(120, (height ?? 200) / 4))
  const v = ix.views.get(id)
  if (!v) return null
  const materialized = v.options?.postgres?.materialized
  const selected = selection?.kind === 'view' && selection.id === id
  const kind = materialized ? 'materialized view' : 'view'
  const className = `sf-card sf-view${materialized ? ' sf-matview' : ''}${selected ? ' sf-selected' : ''}`
  const onClick = (e: MouseEvent) => {
    e.stopPropagation()
    select({ kind: 'view', id })
  }
  const handles = (
    <>
      <Handle type="target" position={Position.Left} id="relation:in" style={{ ...handle, top: HEAD_PORT }} />
      <Handle type="source" position={Position.Right} id="relation:out" style={{ ...handle, top: HEAD_PORT }} />
    </>
  )
  if (detail === 'name') {
    return (
      <div className={`${className} sf-far`} onClick={onClick}>
        {handles}
        <div className="sf-far-name" style={{ fontSize: farName }}>
          <Breakable name={v.name} />
        </div>
        <div className="sf-far-badges" style={{ fontSize: farName * 0.55 }}>
          {kind}
        </div>
      </div>
    )
  }
  return (
    <div className={className} onClick={onClick}>
      {handles}
      <div className="sf-card-head">
        <IconEye size={16} className="sf-muted" />
        <div style={{ minWidth: 0 }}>
          <Text className="sf-card-name" truncate>
            {v.name}
          </Text>
          <Text size="xs" c="dimmed" truncate>
            {ix.path(v.namespace)} · {kind}
          </Text>
        </div>
      </div>
      <Group gap={4} className="sf-badges">
        <Badge size="xs" variant="light" radius="sm">
          reads {v.reads?.length ?? 0}
        </Badge>
      </Group>
      <div className="sf-rows">
        {(v.reads ?? []).map((r) => (
          <div key={r} className="sf-row">
            <IconTable size={13} className="sf-muted" />
            <span className="sf-col-name">{ix.tables.get(r)?.name ?? ix.views.get(r)?.name ?? r}</span>
            <span className="sf-col-type">{ix.path((ix.tables.get(r) ?? ix.views.get(r))?.namespace ?? '')}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

export function NamespaceGroup({ data }: NodeProps) {
  const size = useScreenSize(15, 160)
  return (
    <div className="sf-namespace">
      <div className="sf-namespace-label" style={{ fontSize: size }}>
        {(data as { label: string }).label}
      </div>
    </div>
  )
}
