// The list perspective: every table and view, every column with its type and constraints, to read and compare.
// A partition, which has no columns of its own, and a view, whose columns are its query's, each get one row that
// says what they are.

import { Badge, Group, ScrollArea, Table, Text, TextInput } from '@mantine/core'
import { IconSearch } from '@tabler/icons-react'
import { useMemo, useState, type ReactNode } from 'react'

import { typeLabel, type Column, type Table as SchemaTable, type View } from '../model'
import { useIndex, useWorkbench, type Selection } from '../state'

type Entry = { kind: 'table'; t: SchemaTable; cols: Column[] } | { kind: 'view'; v: View }

export function List() {
  const { model, selection, select } = useWorkbench()
  const ix = useIndex()
  const [filter, setFilter] = useState('')
  const entries = useMemo<Entry[]>(() => {
    const f = filter.trim().toLowerCase()
    const named = (name: string) => !f || name.toLowerCase().includes(f)
    return [
      ...(model.tables ?? [])
        .map((t) => ({ kind: 'table' as const, t, cols: named(t.name) ? t.columns : t.columns.filter((c) => named(c.name)) }))
        .filter((e) => named(e.t.name) || e.cols.length > 0),
      ...(model.views ?? []).filter((v) => named(v.name)).map((v) => ({ kind: 'view' as const, v })),
    ]
  }, [model, filter])
  const fkCols = new Set((model.relationships ?? []).flatMap((r) => r.from.columns))
  const nameOf = (id: string) => ix.tables.get(id)?.name ?? ix.views.get(id)?.name ?? id

  /// The first cell of a relation's first row: its name, and the namespace it is in.
  const relationCell = (id: string, name: string, namespace: string, kind: 'table' | 'view') => (
    <div
      onClick={(e) => {
        e.stopPropagation()
        select({ kind, id })
      }}
    >
      <Text fw={600} size="sm">
        {name}
      </Text>
      <Text size="xs" c="dimmed">
        {ix.path(namespace)}
      </Text>
    </div>
  )
  /// A relation described in one row instead of by its columns.
  const describedRow = (key: string, sel: Selection, selected: boolean, first: ReactNode, what: ReactNode) => (
    <Table.Tr key={key} className={selected ? 'sf-selected-row' : undefined} onClick={() => select(sel)} style={{ cursor: 'pointer' }}>
      <Table.Td>{first}</Table.Td>
      <Table.Td colSpan={6}>
        <Text size="sm" c="dimmed">
          {what}
        </Text>
      </Table.Td>
    </Table.Tr>
  )

  return (
    <div className="sf-perspective-pad">
      <TextInput
        placeholder="Filter tables, views and columns"
        leftSection={<IconSearch size={14} />}
        value={filter}
        onChange={(e) => setFilter(e.currentTarget.value)}
        mb="sm"
        maw={420}
      />
      <ScrollArea h="calc(100% - 48px)">
        <Table highlightOnHover stickyHeader verticalSpacing={4} fz="sm">
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Table</Table.Th>
              <Table.Th>Column</Table.Th>
              <Table.Th>Type</Table.Th>
              <Table.Th>Null</Table.Th>
              <Table.Th>Default</Table.Th>
              <Table.Th>Keys</Table.Th>
              <Table.Th>Comment</Table.Th>
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {entries.map((e) => {
              if (e.kind === 'view') {
                const v = e.v
                const kind = v.options?.postgres?.materialized ? 'materialized view' : 'view'
                return describedRow(
                  v.id,
                  { kind: 'view', id: v.id },
                  selection?.id === v.id,
                  relationCell(v.id, v.name, v.namespace, 'view'),
                  `${kind} · reads ${(v.reads ?? []).map(nameOf).join(', ') || 'nothing it names'}`,
                )
              }
              const t = e.t
              if (t.columns.length === 0) {
                return describedRow(
                  t.id,
                  { kind: 'table', id: t.id },
                  selection?.id === t.id,
                  relationCell(t.id, t.name, t.namespace, 'table'),
                  t.partition_of ? `partition of ${nameOf(t.partition_of.parent)} · ${t.partition_of.bounds}` : 'no columns',
                )
              }
              return e.cols.map((c, i) => {
                const keys: string[] = []
                if (t.primary_key?.columns.includes(c.id)) keys.push('PK')
                if (t.uniques?.some((u) => u.columns.includes(c.id))) keys.push('UQ')
                if (fkCols.has(c.id)) keys.push('FK')
                if (t.options?.iceberg?.identifier_fields?.includes(c.id)) keys.push('ID')
                t.options?.iceberg?.partition_spec?.filter((p) => p.source === c.id).forEach((p) => keys.push(p.transform))
                const selected = selection?.kind === 'column' ? selection.id === c.id : selection?.id === t.id && i === 0
                return (
                  <Table.Tr
                    key={c.id}
                    className={selected ? 'sf-selected-row' : undefined}
                    onClick={() => select({ kind: 'column', id: c.id, table: t.id })}
                    style={{ cursor: 'pointer' }}
                  >
                    <Table.Td>{i === 0 ? relationCell(t.id, t.name, t.namespace, 'table') : null}</Table.Td>
                    <Table.Td ff="monospace">{c.name}</Table.Td>
                    <Table.Td ff="monospace" c="pelican.2">
                      {typeLabel(c.type, model.target, ix.typeNames)}
                    </Table.Td>
                    <Table.Td>{c.nullable ? <Text c="dimmed" size="sm">null</Text> : 'not null'}</Table.Td>
                    <Table.Td ff="monospace" maw={220}>
                      <Text size="xs" truncate>
                        {c.default ?? (c.identity ? (c.identity.always ? 'identity (always)' : 'identity') : '')}
                      </Text>
                    </Table.Td>
                    <Table.Td>
                      <Group gap={3}>
                        {keys.map((k) => (
                          <Badge key={k} size="xs" variant="light" radius="sm">
                            {k}
                          </Badge>
                        ))}
                      </Group>
                    </Table.Td>
                    <Table.Td maw={360}>
                      <Text size="xs" c="dimmed" truncate>
                        {c.comment}
                      </Text>
                    </Table.Td>
                  </Table.Tr>
                )
              })
            })}
          </Table.Tbody>
        </Table>
      </ScrollArea>
    </div>
  )
}
