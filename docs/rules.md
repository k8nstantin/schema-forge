# Rules

Rules are standards: they keep a schema consistent and fit for what it has to do. The architect sets them up once,
on the schema and the levels inside it; the agent reads them before it designs anything and builds inside them, so
neither of you repeats them. Built in milestone 2: `crates/core/src/rules`, the store's `rules` table, the API
under `/api/rules` and `/api/schemas/<name>/rules`, and the Rules perspective.

## Optional

Rules are optional. A schema with nothing linked has no rules; nothing links them for you. Where rules reach from
above (global links), **no rules here** switches every rule off for a schema, a namespace, a family, a group or a
table, with a reason. It holds even over locked rules, since it is the choice not to use rules there at all, and a
rule linked further down still applies.

## Rules made of rules

- A **check** looks at a table and says what breaks it: `pk.present` "Every table has a key".
- A **pack** is a rule made of rules, to any depth; a rule may sit in several packs. `cdc` (CDC-ready) holds the
  whole `pk` pack, `types.time`, `mor.modes`, `cdc.position` and `cdc.source`. Linking a pack brings its tree.
- Every rule holds **hard** (enforced: the agent's change is refused) or **soft** (highlighted only). Each check
  has a default (Must is hard, Should is soft); you set it per link, and the nearest link that says wins. Every
  finding says which it is.

## Sorted so the catalog stays clear

Every rule has two labels, and the catalog is browsed by them:

| Lane: where it applies | Examples |
|---|---|
| **Every database** | nothing without a key; one type per column name; money is decimal; snake_case; descriptions; normalization; SCD2 |
| **MySQL** | tables use InnoDB; text is utf8mb4 |
| **PostgreSQL** | times are `timestamptz`; keys are identity columns, not `serial` |
| **Iceberg** | identifier fields declared; merge-on-read; a format version of 2 or 3 |
| **Between databases** | compatibility (one pack per pair of targets); CDC-ready |

Topics within a lane: keys, types, naming, documentation, normalization, history, storage, cdc, compatibility. A
check keeps its own lane inside a pack of another: `pk.ident` is an Iceberg rule in the shared `pk` pack, and only
checks Iceberg schemas.

## Linked on the hierarchy

A rule is **linked** at a level and applies to every table under it:

```
global (every schema of the workspace)
  └ schema
      └ namespace (and the namespaces inside it)
          └ family (node__, ungrouped, …)
              └ table
      └ group (tables picked by hand, across namespaces and families)
```

- **The nearest link wins.** A table's rules are found by walking from global down to the table: its namespaces
  from the outermost, its family, the groups it is in, itself.
- **An exception** switches a rule, or one rule inside a pack, off at a level and below, and always says why. The
  agent is told the reason. Normalization off on a reporting namespace; "no repeating groups" off on one table
  whose report fixes ten slots, while the rest of Normalization still applies.
- **A locked** link cannot be switched off below the level it is linked at: the architect's guardrail ("nothing
  without a key", locked globally). A lower link of the same rule does not unlock it.
- A link is checked before it is kept: the rule and the level exist, an exception has a reason and switches off
  something that reaches every table under it, and nothing locked is switched off.
- Every change (`link_rule`, `unlink_rule`, `set_group`, `remove_group`) is an operation in the log, announced
  live; global links are logged under `*`.

## Goals

A goal says what the schema has to do and links the packs that get it there, by the schema's type:

| Goal | Links |
|---|---|
| Feed it by CDC | `cdc`; lists what must be set on MySQL (binlog ROW and FULL, GTID, grants) or PostgreSQL (logical WAL, a publication and a slot, replica identity) |
| Build in MySQL and PostgreSQL | the pair's compatibility pack, naming, keys |
| Move PostgreSQL to Iceberg, Move MySQL to Iceberg | the pair's compatibility pack, keys |

Before linking, the perspective shows the gap: what the schema still lacks, from a preview that stores nothing.

## Compatibility

One **type map** per pair of targets (Iceberg, MySQL, PostgreSQL, both ways) grades how each type lands:
**exact**, **widened** (bigger, safe), **decide** (a choice to make: `VARCHAR(n)` or `TEXT`), **lossy**, or **no
type**. Each pair's pack has two checks: nothing lost (Must, breaks on lossy and no type) and every choice made
(Should). The same maps will drive conversion between targets, so a check and a conversion never disagree. The
maps are a first draft, to be checked against each database's documentation.

## Where you work with them

The **Rules perspective** (the UI is the tool; the command line keeps only `schema-forge check`, for CI):

- **Diagram, a level:** the rules that reach it on the left (quiet lines from wider levels, bright ones linked here
  or inside it, landing on the gold row they are linked at), the level and what is inside it in the middle, the
  exceptions on the right in dashed gold. Below: link a rule here (locked, or for every schema), switch one off
  with a reason, take a link away, and what breaks here as references (`@orders.total`) that open the table.
- **Diagram, a rule:** the packs it sits in, the rules it is made of, where it is linked and switched off, what
  breaks it, and for a compatibility rule its type map.
- **Catalog:** every rule by lane and topic, with what it breaks here, or would break if linked.
- **Goals** and **Groups.**
- The **Table** perspective lists the rules on the table, where each comes from, and its findings.

## Rules the agent designs

Nobody knows every rule ahead. So the agent proposes them, the system verifies them, you approve them, and the
system enforces them.

1. **The agent proposes** through the MCP (`propose_rules`), best from what a schema already does: it reads it
   (`describe`) and turns its unwritten conventions into rules, with numbers as evidence ("41 of 42 tables have
   `loaded_at`"). A proposal is a new rule written as a sentence, a catalog rule to link, or an exception.
2. **New rules are sentences, run as data, never code:**

   | Sentence | Example |
   |---|---|
   | columns whose name matches must be of a type, required, described or snake_case | `{"columns": {"name": {"ends_with": "_at"}, "must": {"of_type": ["timestamptz"]}}}` |
   | every table has a column (required, of a type) | `{"has_column": {"column": "loaded_at", "required": true}}` |
   | every table is partitioned by a transform of a column (Iceberg) | `{"partitioned_by": {"transform": "identity", "column": "region"}}` |

   The title you read is made from the sentence itself, so a rule is always exactly what it says.
3. **The system verifies** each: written right for the schema's type; not a repeat of a rule or of another
   proposal; not contradicting a linked rule (a rule that columns could keep only by breaking a linked type rule
   is a conflict); and what it would break if approved. Proposals for every schema are refused: global rules are
   yours.
4. **You approve** in the Rules perspective's Review: hard or soft, approve or reject. A conflict is approved only
   with the contradicted rule switched off there, with a reason. An approved new rule joins the workspace's
   catalog (`custom.<n>`), linked where it was proposed, with who proposed and approved it.
5. **The system enforces**: the agent reads the rules in force (`rules`, `check`) and designs within them; when
   its operations land, a change that breaks a hard rule is refused. The agent can never approve, link or switch
   off a rule itself: that comes back as a proposal.

**What breaks what** (in the Rules perspective) shows it at a glance: hover a rule and the tables that break it
light up, red if it is hard and amber if soft; hover a table and the rules it breaks light up, with what is wrong.
Each linked rule is set hard or soft right there.

## Next

- The design operations through the MCP (`add_table`, `relate`, …), refused when they break a hard rule.
- Rules that shape, not only check, applied by the agent as a plan you approve: SCD2 columns, a surrogate key,
  audit columns, merge-on-read properties (see below).
- Generating the schema, and a migration script that brings a schema to its rules.

The rest of this page is the wider catalog to come.

## What rules will cover

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

For a MySQL or PostgreSQL schema whose changes are captured by Debezium. Add the pack in Standards, to a template or one
schema; a [CDC pipeline](cdc.md) adds it to its source for you.

- **Connector settings, as rules.** How types travel is set here, like any rule, and the pipeline writes
  them out for the connector, so the connector and the designed tables always agree:

  | Rule | Shipped default | Other choices |
  |---|---|---|
  | `decimal.handling.mode` | `precise` (exact decimals) | `double`, `string` |
  | `bigint.unsigned.handling.mode` | `precise` (`decimal(20,0)` on Iceberg; Debezium's own default, `long`, corrupts values above 2^63 − 1) | `long` |
  | `time.precision.mode` | `adaptive_time_microseconds` | `adaptive`, `connect` |
  | `binary.handling.mode` | `bytes` | `base64`, `base64-url-safe`, `hex` |
  | TinyInt-to-boolean converter | on, for the columns marked as booleans | off |
  | zero-date fallback | `null` | a date you choose, per type or column |

  Each choice changes the type mapping at once: set `bigint.unsigned.handling.mode` to `long`, and every
  `BIGINT UNSIGNED` column maps to `long` and is flagged.
- **Keys:** every captured table has a primary key, or a key Debezium is told to use
  (`message.key.columns`); without one there are no reliable updates or deletes downstream.
- **Types Debezium carries badly:** `BIGINT UNSIGNED` flagged unless `bigint.unsigned.handling.mode` is
  `precise`; no `FLOAT` or `DOUBLE` for money; `DECIMAL` flagged unless `decimal.handling.mode` is `precise`; `TIME` within one
  day; no zero dates in `NOT NULL` date and time columns.
- **Booleans:** `TINYINT(1)` used as a boolean is marked so the TinyInt-to-boolean converter covers it, and
  `TINYINT(1)` used as a number is not.
- **Time:** one type for points in time (`TIMESTAMP` arrives zoned in UTC, `DATETIME` without a zone);
  mixing them is flagged.
- **PostgreSQL sources:**
  - **Replica identity:** a captured table without a primary key needs `REPLICA IDENTITY FULL`, or its
    deletes arrive without their data; tables with large values (`text`, `jsonb`, `bytea`) need it too, or
    an update that leaves them unchanged sends a placeholder (`unavailable.value.placeholder`) instead.
  - **`NUMERIC` without a precision** arrives with a different scale per value, which Iceberg's `decimal(p,s)`
    cannot hold: give it a precision and scale.
  - **`INTERVAL`** arrives as microseconds, with months approximated as average days, unless
    `interval.handling.mode` is `string`; flagged where exactness matters.
  - **`TIMETZ`** arrives as a string; `MONEY` takes its scale from `money.fraction.digits`; infinite dates
    become sentinel values.
  - More connector settings as rules: `interval.handling.mode` (shipped `string`), `hstore.handling.mode`
    (shipped `json`), `money.fraction.digits` (shipped `2`).
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
