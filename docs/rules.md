# Rules

The rules are the schema's standards, set before the design starts. They are the agent's cues: it reads
them first, designs by them, and is told plainly when an operation breaks one.

## Where rules come from

```
sf new orders-db --target iceberg
```

1. **Name** the schema.
2. **Type:** MySQL, PostgreSQL or Iceberg.
3. **Rules:** the new schema starts from that type's **template**, and you edit it before you design (in
   the Rules perspective, or in `rules.toml`).
4. **Design** with the agent.

**Templates** are rule sets kept for reuse:

- **Built in**, one per type: `mysql`, `postgres`, `iceberg`, each with sensible defaults for that type
  (below). You can edit them.
- **Your own**, e.g. "our company standard for Iceberg", saved once in `~/.schema-forge/templates/` and
  chosen at `sf new --template <name>`.
- A schema keeps its own copy in `rules.toml`. Editing a template later changes new schemas, not existing
  ones; `sf rules update` shows what would change in one and applies it if you agree.

Every rule has a **severity:** `error` (the operation is refused), `warn` (allowed, marked in the
perspectives) or `off`.

## What rules can cover

### Naming

- case for each kind: tables, columns, views, keys, indexes, `PascalCase` (`TableName`), `camelCase`
  (`tableName`), `snake_case` (`table_name`), `UPPER_SNAKE`
- singular or plural table names
- prefixes and suffixes by kind or tag: `dim_`, `fact_`, `stg_`, `v_` for views, `_id` for keys
- templates for constraint and index names: `pk_{table}`, `fk_{table}_{referenced_table}`,
  `ix_{table}_{columns}`
- boolean columns start with `is_` or `has_`; time columns end with `_at`, dates with `_on`
- the longest name the target allows (PostgreSQL 63, MySQL 64), reserved words refused
- a list of approved abbreviations (`qty`, `amt`), others spelled out

### Keys and identity

- every table has a primary key
- the surrogate key's name and type: `id bigint` identity, UUID, UUIDv7
- business keys: required and unique where a table has one
- composite primary keys allowed or not
- every foreign key indexed
- the default `on delete` / `on update` for foreign keys
- Iceberg: identifier fields required, and what a logical relationship must point at

### Columns and types

- types allowed and forbidden: no `float` or `double` for money (use `decimal`), no `varchar` without
  a length on MySQL, `timestamptz` over `timestamp` on PostgreSQL
- defaults for new columns: `NOT NULL` unless said otherwise, string lengths, decimal precision
- enums: inline (`ENUM`, PostgreSQL enum types) or lookup tables
- character set and collation (MySQL `utf8mb4` / `utf8mb4_0900_ai_ci`)

### Standard columns

- audit columns every table carries: `created_at`, `updated_at`, `created_by`
- soft delete: `deleted_at`
- multi-tenant: `tenant_id` on every table, first in every key
- their names, types and position, added by the agent when it creates a table

### Patterns

What a table tagged with a pattern must have; the agent applies the pattern on request
(`apply_pattern`), and `check` reports what is missing:

- **SCD Type 1:** overwrite in place, `updated_at`
- **SCD Type 2:** surrogate key, business key, the validity columns and their names (`valid_from` /
  `valid_to`, or your own), unique (business key, start of validity)
- **SCD Types 3, 4, 6:** previous-value columns, a history table, the combination
- **Star schema:** `fact` tables reference only `dimension` tables, by surrogate key; dimensions never
  reference facts
- **Append-only / event tables:** no update columns, an event time, partitioned by it on Iceberg
- **Bridge tables:** exactly two relationships, their pair unique

### Documentation

- a comment on every table, view and column (or only on tables, or on keys)
- tags and an area on every table

### Database views

- no `SELECT *`
- name prefix, comment required
- materialized views only where allowed; how they are refreshed is documented

### Change safety

- destructive changes (drops, narrowed types, `NOT NULL` added) need an explicit flag
- renames instead of drop-and-add
- after a version is locked, only additive changes (new tables and nullable columns) without a new major
  version

### Size

- the most columns a table may have, the most indexes, the most tables in an area

## The built-in templates

What each type starts with. Every value can be changed.

| | MySQL | PostgreSQL | Iceberg |
|---|---|---|---|
| **Names** | `snake_case`, plural tables | `snake_case`, plural tables | `snake_case`, plural tables |
| **Keys** | `id bigint unsigned AUTO_INCREMENT`; foreign keys indexed, `on delete restrict` | `id bigint GENERATED ALWAYS AS IDENTITY`; foreign keys indexed, `on delete restrict` | identifier fields required; relationships logical |
| **Types** | `InnoDB`, `utf8mb4`, `utf8mb4_0900_ai_ci`; `decimal` for money; `datetime(6)` | `timestamptz`, `text` over `varchar(n)`, `numeric` for money | `decimal` for money, `timestamptz`; format version 2 |
| **Table defaults** | `ROW_FORMAT=DYNAMIC` | | **merge-on-read** for deletes, updates and merges (`write.delete.mode`, `write.update.mode`, `write.merge.mode` = `merge-on-read`); Parquet, `zstd`; a partition spec on every table with a time column (by `day` unless set); a sort order on every table |
| **Comments** | on every table | on every table | on every table |
| **Change safety** | destructive changes flagged | destructive changes flagged | destructive changes flagged; no partition change without a flag |

## How the agent uses them

- `guide` gives the agent the schema's type and rules in plain words before it designs anything: "this
  is an Iceberg schema; tables are `snake_case` and plural; tables tagged `scd2` follow SCD Type 2 with
  `valid_from`/`valid_to`; new tables are merge-on-read and partitioned by day".
- `rules` lists each rule, its severity and the tables it applies to; `check` says what passes and fails.
- Operations are named and shaped by the rules (a new table gets its audit columns, a new foreign key its
  templated name and its index), and refused with the rule's name and the expected form when they break
  one.
