# Rules

Rules are standards: they keep a schema consistent. Every integer is the same kind of integer, every
string the same kind of string, every name in the same form, so you and the agent both know what the
schema looks like before a table exists. The agent reads them first, designs by them, and is told plainly
when an operation breaks one.

## Two places: Standards, and the schema

Schema Forge has two parts, each with its own UI:

```
 Standards                                   Schemas
 ─────────                                   ───────
 the types: MySQL · PostgreSQL · Iceberg      name ──► type ──► rules ──► design with the agent
 each type's default rules                                 ▲
 your own templates, per type          ──────── copied ────┘
```

**Standards** is where rules are configured, by type, before any schema exists:

- **One default rule set per type.** MySQL, PostgreSQL and Iceberg each come with built-in defaults
  (below), and you edit them: "our Iceberg tables are merge-on-read, `snake_case`, partitioned by day".
- **Your own templates, per type**, beside the default: "billing standard (PostgreSQL)", "lakehouse
  (Iceberg)". Each says which type it is for.
- The Standards UI shows every rule with its setting, its severity and an example of what it accepts and
  refuses, so a rule reads clearly before it is ever used.
- Kept in `~/.schema-forge/standards/`, one file per type and template, and shareable: point Schema Forge
  at a shared folder or git repo and a team uses the same standards.
- The agent can help here too: "make our Iceberg default copy-on-write for deletes" is a change to the
  standard, shown for you to accept.

**A schema** chooses its rules when it is created, and does not have to have any:

1. **Name** it.
2. **Type:** MySQL, PostgreSQL or Iceberg.
3. **Rules,** one of:
   - **none:** design freely; only the model's own checks apply;
   - **a template:** the type's default, or one of your own for that type;
   - **your own:** start from a template and change it for this schema (and save it as a new template
     if you like).
4. **Design** with the agent.

```
schema-forge new orders-db --target iceberg --rules default    # Iceberg's default rules
schema-forge new ledger --target postgres --rules billing       # your own PostgreSQL template
schema-forge new scratch --target mysql --rules none            # no rules
```

A schema with rules keeps its own copy in `rules.toml`. A later change to a standard affects new schemas, not
existing ones; `schema-forge rules update` shows what would change in a schema and applies it if you agree.

Every rule has a **severity:** `error` (the operation is refused), `warn` (allowed, marked in the
perspectives) or `off`.

## What rules can cover

### Type standards

The heart of consistency: one type for each kind of data, used everywhere. The table below is what ships
(agreed with the operator, 2026-11-20); every value can be changed in Standards.

| Kind of data | e.g. PostgreSQL | e.g. MySQL | e.g. Iceberg |
|---|---|---|---|
| integers | `bigint` | `bigint` | `long` |
| keys | `bigint` identity | `bigint unsigned` auto-increment | `long` |
| strings | `text` | `varchar(255)` | `string` |
| short codes | `varchar(32)` | `varchar(32)` | `string` |
| money | `numeric(18,2)` | `decimal(18,2)` | `decimal(18,2)` |
| other decimals | `numeric(18,6)` | `decimal(18,6)` | `decimal(18,6)` |
| booleans | `boolean` | `tinyint(1)` | `boolean` |
| points in time | `timestamptz` | `datetime(6)` | `timestamptz` |
| dates | `date` | `date` | `date` |
| identifiers from elsewhere | `uuid` | `char(36)` | `uuid` |
| documents | `jsonb` | `json` | `variant` |

- The agent asks for a **kind** ("an integer", "money") and gets the standard type; a column of another
  type is refused or warned, with the standard named.
- Each kind can say when it applies (columns ending `_amount` are money; `_at` are points in time), so
  existing schemas can be checked too.

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

### Debezium (a rule pack)

For a MySQL schema whose changes are captured by Debezium. Add the pack in Standards, to a template or one
schema; a [CDC pipeline](cdc.md) adds it to its source for you.

- **Keys:** every captured table has a primary key, or a key Debezium is told to use
  (`message.key.columns`); without one there are no reliable updates or deletes downstream.
- **Types Debezium carries badly:** `BIGINT UNSIGNED` only with `bigint.unsigned.handling.mode=precise`;
  no `FLOAT` or `DOUBLE` for money; `DECIMAL` only with `decimal.handling.mode=precise`; `TIME` within one
  day; no zero dates in `NOT NULL` date and time columns.
- **Booleans:** `TINYINT(1)` used as a boolean is marked so the TinyInt-to-boolean converter covers it, and
  `TINYINT(1)` used as a number is not.
- **Time:** one type for points in time (`TIMESTAMP` arrives zoned in UTC, `DATETIME` without a zone);
  mixing them is flagged.
- **Names:** column names valid for Avro (`[A-Za-z_][A-Za-z0-9_]*`) when the pipeline uses Avro, or the
  name adjustment noted; no source column named like a CDC field (`__op`, `__deleted`, `__source_ts_ms`).
- **Enums:** a change to `ENUM` or `SET` values flagged, since it changes what consumers receive.
- **Schema changes:** renames and type changes on captured tables flagged as changes every downstream
  consumer must take; additions pass.

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

## Each type's default rules

What each type starts with, as shipped. Every value can be changed in Standards.

| | MySQL | PostgreSQL | Iceberg |
|---|---|---|---|
| **Names** | `snake_case`, plural tables | `snake_case`, plural tables | `snake_case`, plural tables |
| **Keys** | `id bigint unsigned AUTO_INCREMENT`; foreign keys indexed, `on delete restrict` | `id bigint GENERATED ALWAYS AS IDENTITY`; foreign keys indexed, `on delete restrict` | identifier fields required; relationships logical |
| **Types** | `InnoDB`, `utf8mb4`, `utf8mb4_0900_ai_ci`; `decimal` for money; `datetime(6)` | `timestamptz`, `text` over `varchar(n)`, `numeric` for money | `decimal` for money, `timestamptz`; **format version 3** |
| **Table defaults** | `ROW_FORMAT=DYNAMIC` | | **merge-on-read** for deletes, updates and merges (`write.delete.mode`, `write.update.mode`, `write.merge.mode` = `merge-on-read`); Parquet, `zstd`; a partition spec on every table with a time column (by `day` unless set); a sort order on every table |
| **Comments** | on every table | on every table | on every table |
| **Change safety** | destructive changes flagged | destructive changes flagged | destructive changes flagged; no partition change without a flag |

## The Standards UI

Rules are a product of their own, with a rich UI:

- **Catalog:** every rule by category (types, naming, keys, standard columns, patterns, documentation,
  views, change safety, size), each with its setting and severity, switchable in place.
- **See before you set:** every rule shows what it accepts and what it refuses, with live examples that
  change as you edit it ("`orderTotal` is refused; expected `order_total`").
- **Try it on a schema:** run a template against an existing or imported schema and see every table and
  column it would pass or fail, before you adopt it.
- **Compare:** two templates, or a template against a schema's copy, side by side.
- **Type standards as a table:** each kind of data and its type, per target, edited like a spreadsheet.
- **Patterns drawn:** an SCD Type 2 or star-schema pattern shown as a small diagram of what it adds.
- **History:** who changed a standard and when; templates are files, so git keeps them too.
- **With the agent:** "make money `decimal(19,4)` in our PostgreSQL standard" becomes a change shown for
  you to accept.

## How the agent uses them

- `guide` gives the agent the schema's type and rules in plain words before it designs anything: "this
  is an Iceberg schema; tables are `snake_case` and plural; tables tagged `scd2` follow SCD Type 2 with
  `valid_from`/`valid_to`; new tables are merge-on-read and partitioned by day".
- `rules` lists each rule, its severity and the tables it applies to; `check` says what passes and fails.
- Operations are named and shaped by the rules (a new table gets its audit columns, a new foreign key its
  templated name and its index), and refused with the rule's name and the expected form when they break
  one.
