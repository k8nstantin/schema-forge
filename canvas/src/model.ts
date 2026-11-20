// The schema model as the server sends it: the same JSON as the Rust model (crates/core/src/model.rs).

export type Target = 'mysql' | 'postgres' | 'iceberg'

export interface SchemaInfo {
  name: string
  target: Target
  format: number
}

export interface DataType {
  name: string
  length?: number
  precision?: number
  scale?: number
  unsigned?: boolean
  with_time_zone?: boolean
  values?: string[]
  of?: DataType
  key?: DataType
  element_id?: number
  key_id?: number
  element_nullable?: boolean
  fields?: StructField[]
  type?: string
  dimensions?: number
  charset?: string
  text?: string
}

export interface StructField {
  field_id: number
  name: string
  nullable: boolean
  type: DataType
  comment?: string
}

export interface Column {
  id: string
  name: string
  type: DataType
  nullable: boolean
  default?: string
  generated?: { expression: string; stored: boolean }
  identity?: { always?: boolean; options?: string }
  collation?: string
  comment?: string
  field_id?: number
  on_update?: string
}

export interface IndexPart {
  column?: string
  expression?: string
  direction?: 'asc' | 'desc'
  nulls?: 'first' | 'last'
  length?: number
}

export interface Index {
  id: string
  name: string
  unique?: boolean
  parts: IndexPart[]
  method?: string
  include?: string[]
  where?: string
}

export interface PartitionField {
  source: string
  transform: string
  name?: string
}

export interface SortField {
  source: string
  transform?: string
  direction: 'asc' | 'desc'
  nulls: 'first' | 'last'
}

export interface Table {
  id: string
  namespace: string
  name: string
  comment?: string
  notes?: string
  tags?: string[]
  area?: string
  columns: Column[]
  primary_key?: { name?: string; columns: string[] }
  uniques?: { id: string; name?: string; columns: string[]; nulls_distinct?: boolean }[]
  checks?: { id: string; name?: string; expression: string }[]
  indexes?: Index[]
  patterns?: Record<string, unknown>
  partition_of?: { parent: string; bounds: string }
  options?: {
    mysql?: Record<string, unknown>
    postgres?: {
      tablespace?: string
      unlogged?: boolean
      partition_by?: string
      partition_policy?: {
        interval?: string
        retention?: string
        managed_by?: string
        series?: { interval: string; first: string; last: string; count: number; kept: string }
      }
      inherits?: string[]
      storage?: string
    }
    iceberg?: {
      format_version?: number
      identifier_fields?: string[]
      partition_spec?: PartitionField[]
      sort_order?: SortField[]
      properties?: Record<string, string>
      location?: string
    }
  }
}

export interface Relationship {
  id: string
  name?: string
  from: { table: string; columns: string[] }
  to: { table: string; columns: string[] }
  enforced: boolean
  on_delete?: string
  on_update?: string
}

export interface View {
  id: string
  namespace: string
  name: string
  comment?: string
  notes?: string
  tags?: string[]
  definition: string
  reads?: string[]
  options?: {
    postgres?: { materialized?: boolean; with_data?: boolean; indexes?: Index[] }
    iceberg?: { dialect?: string; representations?: Record<string, string> }
    mysql?: Record<string, unknown>
  }
}

export interface Namespace {
  id: string
  name: string
  parent?: string
  comment?: string
}

export interface Schema {
  format: number
  target: Target
  namespaces?: Namespace[]
  areas?: { id: string; name: string; colour?: string }[]
  tables?: Table[]
  relationships?: Relationship[]
  views?: View[]
  sequences?: { id: string; namespace: string; name: string; owned_by?: string }[]
  types?: { id: string; namespace: string; name: string; kind: string; values?: string[] }[]
  kept?: { id: string; kind: string; text: string; after?: string }[]
}

/// A type as its target writes it, short: `varchar(200)`, `numeric(12,2)`, `list<string>`, `struct<3>`.
export function typeLabel(t: DataType, target: Target, typeNames: Map<string, string>): string {
  if (t.name === 'verbatim') return t.text ?? '?'
  if (t.name === 'user') return typeNames.get(t.type ?? '') ?? 'type'
  const args = (...xs: (number | undefined)[]) => {
    const v = xs.filter((x) => x !== undefined)
    return v.length ? `(${v.join(',')})` : ''
  }
  switch (t.name) {
    case 'array':
      return `${t.of ? typeLabel(t.of, target, typeNames) : '?'}${'[]'.repeat(t.dimensions ?? 1)}`
    case 'list':
      return `list<${t.of ? typeLabel(t.of, target, typeNames) : '?'}>`
    case 'map':
      return `map<${t.key ? typeLabel(t.key, target, typeNames) : '?'}, ${t.of ? typeLabel(t.of, target, typeNames) : '?'}>`
    case 'struct':
      return `struct<${t.fields?.length ?? 0}>`
    case 'varchar':
    case 'char':
    case 'bit':
    case 'varbit':
      return `${t.name}${args(t.length)}`
    case 'numeric':
    case 'decimal':
      return `${t.name}${args(t.precision, t.scale)}`
    case 'timestamp':
    case 'time':
      if (target === 'postgres') return `${t.name}${t.with_time_zone ? 'tz' : ''}${args(t.precision)}`
      return t.name
    default:
      return `${t.name}${t.unsigned ? ' unsigned' : ''}`
  }
}

/// Whether a type has fields to unfold (an Iceberg struct, or a list or map of one).
export function nested(t: DataType): StructField[] {
  if (t.name === 'struct') return t.fields ?? []
  if ((t.name === 'list' || t.name === 'map') && t.of) return nested(t.of)
  return []
}

/// The schema as the perspectives show it (crates/core/src/shape.rs): families, stacked copies, links.
export interface Shape {
  tables: { table: string; family: string; copy_of?: string; stack?: { series: string; label: string; count: number } }[]
  families: { namespace: string; name: string; tables: number; copies: number }[]
  links: { from: string; column: string; to: string; declared: boolean; shared: boolean }[]
}
