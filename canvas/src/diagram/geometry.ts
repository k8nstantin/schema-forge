// A card's geometry, shared by the layout (which sizes cards and places the ports edges are routed to) and the
// cards (which draw them and put their handles on those ports). A card has the same size and its rows the same
// places at every zoom: only how much text it shows changes, so routed edges always meet the right row.

import { nested, type Schema, type Table } from '../model'

export const CARD_WIDTH = 300
/// Where edges meet a card that are about the whole relation, not one column: the middle of the header.
export const HEAD_PORT = 24
const HEADER = 54
const BADGES = 26
const ROWS_PAD_TOP = 4
const ROWS_PAD_BOTTOM = 6
const ROW = 22

export interface CardBadge {
  label: string
  tip: string
  strong?: boolean
}

/// What a table is at a glance: its format, write mode, partitioning, sort and tags.
export function tableBadges(t: Table): CardBadge[] {
  const out: CardBadge[] = []
  const ice = t.options?.iceberg
  if (ice) {
    if (ice.format_version) out.push({ label: `v${ice.format_version}`, tip: `Iceberg format version ${ice.format_version}`, strong: true })
    const modes = ['write.delete.mode', 'write.update.mode', 'write.merge.mode'].map((k) => ice.properties?.[k])
    if (modes.some((m) => m === 'merge-on-read')) {
      out.push({ label: 'MoR', tip: `merge-on-read: ${modes.map((m) => m ?? 'default').join(' / ')} (delete / update / merge)` })
    } else if (modes.some((m) => m === 'copy-on-write')) {
      out.push({ label: 'CoW', tip: 'copy-on-write' })
    }
    if (ice.partition_spec?.length) out.push({ label: `partitioned ×${ice.partition_spec.length}`, tip: ice.partition_spec.map((p) => p.transform).join(', ') })
    if (ice.sort_order?.length) out.push({ label: 'sorted', tip: `${ice.sort_order.length} sort fields` })
  }
  const pg = t.options?.postgres
  if (pg?.partition_by) out.push({ label: 'partitioned', tip: `PARTITION BY ${pg.partition_by}`, strong: true })
  const series = pg?.partition_policy?.series
  if (series) out.push({ label: `${series.count} ${series.interval === '1 day' ? 'daily' : 'monthly'}`, tip: `${series.count} partitions, ${series.first} up to ${series.last}` })
  if (t.partition_of) out.push({ label: 'partition', tip: t.partition_of.bounds })
  for (const tag of t.tags ?? []) out.push({ label: tag, tip: `tag ${tag}` })
  return out
}

/// Rows a table shows: its columns and the fields of each unfolded column; a partition, which has no columns of
/// its own, shows one row naming whose it has.
export function tableRows(t: Table, unfolded: Set<string>): number {
  return t.columns.reduce((n, c) => n + 1 + (unfolded.has(c.id) ? nested(c.type).length : 0), 0) || 1
}

export function tableHeight(t: Table, unfolded: Set<string>): number {
  return cardHeight(tableRows(t, unfolded), tableBadges(t).length > 0)
}

/// A view shows a badge row and one row for each relation it reads.
export function viewHeight(model: Schema, id: string): number {
  return cardHeight(model.views?.find((v) => v.id === id)?.reads?.length || 1, true)
}

function cardHeight(rows: number, badges: boolean): number {
  return HEADER + (badges ? BADGES : 0) + ROWS_PAD_TOP + rows * ROW + ROWS_PAD_BOTTOM
}

/// The middle of column `i`'s row, from the card's top, with the unfolded fields above it counted.
export function columnPort(t: Table, i: number, unfolded: Set<string>): number {
  let rows = 0
  for (let n = 0; n < i; n++) rows += 1 + (unfolded.has(t.columns[n].id) ? nested(t.columns[n].type).length : 0)
  return HEADER + (tableBadges(t).length > 0 ? BADGES : 0) + ROWS_PAD_TOP + rows * ROW + ROW / 2
}
