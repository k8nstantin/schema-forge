// The Inspector: everything about what is selected, the same whichever perspective it was selected in.

import { ActionIcon, Badge, Code, Divider, Group, ScrollArea, Stack, Table, Text, Tooltip } from '@mantine/core'
import { IconCopy } from '@tabler/icons-react'
import type { ReactNode } from 'react'

import { nested, typeLabel, type StructField, type Table as TableModel } from '../model'
import { reference, referenceWithContext, useIndex, useWorkbench } from '../state'

export function Inspector() {
  const { model, selection } = useWorkbench()
  const ix = useIndex()
  if (!selection) {
    return (
      <Stack p="md" gap="xs">
        <Text fw={600}>Nothing selected</Text>
        <Text size="sm" c="dimmed">
          Select a table, a view or a column. Press C to copy its reference for your prompt, Shift+C to copy it with
          context.
        </Text>
      </Stack>
    )
  }
  const ref = reference(selection, ix)
  const withContext = referenceWithContext(selection, ix, model)
  return (
    <ScrollArea h="100%">
      <Stack p="md" gap="sm">
        <Group justify="space-between" wrap="nowrap">
          <Code fz="sm">{ref}</Code>
          <Tooltip label="Copy the reference (C), with context (Shift+C)">
            <ActionIcon variant="subtle" onClick={() => navigator.clipboard.writeText(withContext ?? ref ?? '')}>
              <IconCopy size={16} />
            </ActionIcon>
          </Tooltip>
        </Group>
        {selection.kind === 'table' && <TableDetail table={ix.tables.get(selection.id)!} />}
        {selection.kind === 'view' && <ViewDetail id={selection.id} />}
        {selection.kind === 'column' && <ColumnDetail id={selection.id} />}
      </Stack>
    </ScrollArea>
  )
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <Group gap="xs" wrap="nowrap" align="flex-start">
      <Text size="xs" c="dimmed" w={96} style={{ flexShrink: 0 }}>
        {label}
      </Text>
      <div style={{ minWidth: 0, fontSize: 13 }}>{children}</div>
    </Group>
  )
}

function TableDetail({ table: t }: { table: TableModel }) {
  const { model, select } = useWorkbench()
  const ix = useIndex()
  const col = (id: string) => ix.columns.get(id)?.column.name ?? id
  const ice = t.options?.iceberg
  const pg = t.options?.postgres
  const outgoing = (model.relationships ?? []).filter((r) => r.from.table === t.id)
  const incoming = (model.relationships ?? []).filter((r) => r.to.table === t.id)
  const readBy = (model.views ?? []).filter((v) => v.reads?.includes(t.id))
  return (
    <>
      <Text fw={700} size="lg">
        {t.name}
      </Text>
      <Row label="namespace">{ix.path(t.namespace)}</Row>
      {t.comment && <Row label="comment">{t.comment}</Row>}
      {t.notes && (
        <Row label="design notes">
          <Text size="xs" style={{ whiteSpace: 'pre-wrap' }} c="dimmed">
            {t.notes}
          </Text>
        </Row>
      )}
      <Row label="columns">{t.columns.length}</Row>
      {t.primary_key && <Row label="primary key">{t.primary_key.columns.map(col).join(', ')}</Row>}
      {(t.uniques ?? []).map((u) => (
        <Row key={u.id} label="unique">
          {u.columns.map(col).join(', ')} {u.name && <Text span c="dimmed" size="xs">{u.name}</Text>}
        </Row>
      ))}
      {(t.checks ?? []).map((c) => (
        <Row key={c.id} label="check">
          <Code fz="xs">{c.expression}</Code>
        </Row>
      ))}
      {(t.indexes ?? []).map((i) => (
        <Row key={i.id} label={i.unique ? 'unique index' : 'index'}>
          {i.name}: {i.parts.map((p) => (p.column ? col(p.column) : p.expression)).join(', ')}
          {i.where && <Text span c="dimmed" size="xs"> where {i.where}</Text>}
        </Row>
      ))}
      {ice && (
        <>
          <Divider label="Iceberg" labelPosition="left" />
          {ice.format_version && <Row label="format">version {ice.format_version}</Row>}
          {ice.identifier_fields?.length ? <Row label="identifier">{ice.identifier_fields.map(col).join(', ')}</Row> : null}
          {ice.partition_spec?.length ? (
            <Row label="partitions">
              <Group gap={4}>
                {ice.partition_spec.map((p) => (
                  <Badge key={p.source + p.transform} size="sm" variant="light">
                    {p.transform === 'identity' ? col(p.source) : `${p.transform}(${col(p.source)})`}
                  </Badge>
                ))}
              </Group>
            </Row>
          ) : null}
          {ice.sort_order?.length ? (
            <Row label="sort order">
              {ice.sort_order.map((s) => `${col(s.source)} ${s.direction} nulls ${s.nulls}`).join(', ')}
            </Row>
          ) : null}
          {Object.entries(ice.properties ?? {}).map(([k, v]) => (
            <Row key={k} label={k.replace(/^write\./, '')}>
              {v}
            </Row>
          ))}
        </>
      )}
      {pg?.partition_by && <Row label="partitioned">{pg.partition_by}</Row>}
      {pg?.partition_policy?.series && (
        <Row label="series">
          {pg.partition_policy.series.count} × {pg.partition_policy.series.interval}, {pg.partition_policy.series.first} up to{' '}
          {pg.partition_policy.series.last}
        </Row>
      )}
      {t.partition_of && <Row label="partition of">{ix.tables.get(t.partition_of.parent)?.name} {t.partition_of.bounds}</Row>}
      {(outgoing.length > 0 || incoming.length > 0 || readBy.length > 0) && <Divider label="Relationships" labelPosition="left" />}
      {outgoing.map((r) => (
        <Row key={r.id} label={r.enforced ? 'references' : 'refers to (logical)'}>
          <Text span c="pelican.3" style={{ cursor: 'pointer' }} onClick={() => select({ kind: 'table', id: r.to.table })}>
            {ix.tables.get(r.to.table)?.name}
          </Text>{' '}
          ({r.from.columns.map(col).join(', ')}){r.on_delete ? ` on delete ${r.on_delete.replace('_', ' ')}` : ''}
        </Row>
      ))}
      {incoming.map((r) => (
        <Row key={r.id} label="referenced by">
          <Text span c="pelican.3" style={{ cursor: 'pointer' }} onClick={() => select({ kind: 'table', id: r.from.table })}>
            {ix.tables.get(r.from.table)?.name}
          </Text>
        </Row>
      ))}
      {readBy.map((v) => (
        <Row key={v.id} label="read by view">
          <Text span c="pelican.3" style={{ cursor: 'pointer' }} onClick={() => select({ kind: 'view', id: v.id })}>
            {v.name}
          </Text>
        </Row>
      ))}
    </>
  )
}

function ViewDetail({ id }: { id: string }) {
  const { select } = useWorkbench()
  const ix = useIndex()
  const v = ix.views.get(id)!
  return (
    <>
      <Text fw={700} size="lg">
        {v.name}
      </Text>
      <Row label="namespace">{ix.path(v.namespace)}</Row>
      {v.options?.postgres?.materialized && <Row label="kind">materialized view</Row>}
      {v.comment && <Row label="comment">{v.comment}</Row>}
      {v.notes && <Row label="design notes"><Text size="xs" style={{ whiteSpace: 'pre-wrap' }} c="dimmed">{v.notes}</Text></Row>}
      {(v.reads ?? []).map((r) => (
        <Row key={r} label="reads">
          <Text span c="pelican.3" style={{ cursor: 'pointer' }} onClick={() => select({ kind: ix.views.has(r) ? 'view' : 'table', id: r })}>
            {(ix.tables.get(r) ?? ix.views.get(r))?.name}
          </Text>
        </Row>
      ))}
    </>
  )
}

function ColumnDetail({ id }: { id: string }) {
  const { model, select } = useWorkbench()
  const ix = useIndex()
  const found = ix.columns.get(id)
  if (!found) return null
  const { table: t, column: c } = found
  const fields = nested(c.type)
  const keys = [
    t.primary_key?.columns.includes(id) && 'primary key',
    t.uniques?.some((u) => u.columns.includes(id)) && 'unique',
    t.options?.iceberg?.identifier_fields?.includes(id) && 'identifier field',
    ...(t.options?.iceberg?.partition_spec ?? []).filter((p) => p.source === id).map((p) => `partition ${p.transform}`),
  ].filter(Boolean)
  const relationships = model.relationships ?? []
  /// One end of a relationship, `table.column`, that selects the column.
  const end = (table: string, columns: string[]) => (
    <Text span c="pelican.3" style={{ cursor: 'pointer' }} onClick={() => select({ kind: 'column', id: columns[0], table })}>
      {ix.tables.get(table)?.name}.{columns.map((x) => ix.columns.get(x)?.column.name ?? x).join(', ')}
    </Text>
  )
  return (
    <>
      <Text fw={700} size="lg">
        {c.name} <Text span c="dimmed" size="sm">in {t.name}</Text>
      </Text>
      <Row label="type">
        <Code fz="xs">{typeLabel(c.type, model.target, ix.typeNames)}</Code>
      </Row>
      <Row label="nullable">{c.nullable ? 'yes' : 'no'}</Row>
      {c.field_id !== undefined && <Row label="field id">{c.field_id}</Row>}
      {c.default && <Row label="default"><Code fz="xs">{c.default}</Code></Row>}
      {c.identity && <Row label="identity">{c.identity.always ? 'always' : 'by default'}</Row>}
      {c.generated && <Row label="generated"><Code fz="xs">{c.generated.expression}</Code></Row>}
      {c.comment && <Row label="comment">{c.comment}</Row>}
      {keys.length > 0 && <Row label="keys">{keys.join(', ')}</Row>}
      {relationships
        .filter((r) => r.from.columns.includes(id))
        .map((r) => (
          <Row key={r.id} label={r.enforced ? 'references' : 'refers to (logical)'}>
            {end(r.to.table, r.to.columns)}
          </Row>
        ))}
      {relationships
        .filter((r) => r.to.columns.includes(id))
        .map((r) => (
          <Row key={r.id} label="referenced by">
            {end(r.from.table, r.from.columns)}
          </Row>
        ))}
      {fields.length > 0 && (
        <>
          <Divider label="Fields" labelPosition="left" />
          <FieldTable fields={fields} depth={0} />
        </>
      )}
    </>
  )
}

function FieldTable({ fields, depth }: { fields: StructField[]; depth: number }) {
  const { model } = useWorkbench()
  const ix = useIndex()
  return (
    <Table fz="xs" verticalSpacing={2}>
      <Table.Tbody>
        {fields.flatMap((f) => [
          <Table.Tr key={f.field_id}>
            <Table.Td style={{ paddingLeft: 8 + depth * 14 }} ff="monospace">
              {f.name}
            </Table.Td>
            <Table.Td ff="monospace" c="pelican.2">
              {typeLabel(f.type, model.target, ix.typeNames)}
            </Table.Td>
            <Table.Td c="dimmed">#{f.field_id}</Table.Td>
            <Table.Td c="dimmed">{f.nullable ? '' : 'required'}</Table.Td>
          </Table.Tr>,
          ...(nested(f.type).length ? [<Table.Tr key={`${f.field_id}-n`}><Table.Td colSpan={4} p={0}><FieldTable fields={nested(f.type)} depth={depth + 1} /></Table.Td></Table.Tr>] : []),
        ])}
      </Table.Tbody>
    </Table>
  )
}
