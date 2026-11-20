# Schema Forge

**An ER design tool with many useful perspectives: build your database schema together with your coding
agent, and watch it take shape.**

**You direct; the agent builds.** You never edit the schema by hand: you look at it from every side, point
at what you mean, and tell the agent what to do. The agent works through Schema Forge's MCP, and every
change appears at once on a rich, live perspective that you both see. When the schema is right, export it for MySQL, PostgreSQL or Apache Iceberg.

It works with **any coding agent that speaks MCP** (Claude Code first). The MCP is the enforcer: every
change goes through it and is checked against the schema's rules. More agents and more databases come
later. How it compares with what exists: [docs/market.md](docs/market.md).

```
 you ──prompt──► coding agent ──MCP──► schema-forge ──► live perspectives (you see them, the agent can render them)
                                        │
                                        └──► export   (MySQL, PostgreSQL, Iceberg)
```

## Start

You and the agent take the same path:

```
 you    ──► Schema Forge ──┐
                           ├──► schema ──► type ──► rules ──► design
 agent  ──► MCP ───────────┘
```

1. **Schema:** open one, or create one with a name.
2. **Type:** MySQL, PostgreSQL or Iceberg.
3. **Rules:** none, a template (the type's default, or your own), or its own made from a template.
4. **Design:** together, live.

```
schema-forge serve      # the workspace opens; the MCP is added for Claude Code
```

The agent can take every step itself, through the MCP, while you watch: "create an Iceberg schema called
orders, with our lakehouse rules, then design an order system; orders are SCD Type 2". It never designs
before it knows the schema's type and has read its rules; those are its cues.

| Step | The agent's MCP tools |
|---|---|
| schema | `schemas` (list), `open_schema`, `new_schema` (name, type) |
| type | part of the schema; `describe` says it |
| rules | `templates` (per type), `set_rules`, `rules`, `guide` (the rules in plain words) |
| design | `describe`, `render`, `check`, the operations (`add_table`, `relate`, `add_view`, …), `apply_pattern` |

Rules are standards that keep a schema consistent: every integer the same type, every string the same,
every name the same form; naming, keys, standard columns, patterns such as SCD Type 2, and target defaults
such as merge-on-read on Iceberg. They are configured by type in their own UI, **Standards**. The full
catalog: [docs/rules.md](docs/rules.md).

## What it does

- **The agent builds; you direct.** The agent reads the schema and the rules, then changes it one
  operation at a time: add a table, a column, a relation, a view. Each operation is checked against the
  rules before it applies. You never edit: you prompt, and you point.
- **Shows it, live, from several sides.** Every change lands in every perspective as it happens:

  | Perspective | Shows |
  |---|---|
  | **Diagram** | tables and views as cards, with their relationships |
  | **List** | every table and view with its columns, types and constraints |
  | **Definition** | the SQL definition of what you selected, in your target database |
  | **Categories** | the schema grouped by area or tag |
  | **Consistency** | every inconsistency: one column with different types, mismatched relationship ends, drifting lengths, mixed time types, CDC hazards; each with a fix the agent can make |
  | **Custom** | the tables, columns and grouping you choose, saved with the project |

- **Zooms from the big picture into one table.** The diagram shows more as you zoom, without losing your
  place:

  | Level | Shows |
  |---|---|
  | **Whole schema** | areas as regions, tables as named blocks, how the areas connect |
  | **Area** | tables with their keys, and the relationships between them |
  | **Table** | the full card: every column, type, constraint, index, tag and rule result |
  | **Focus** | one table and everything about it: its relationships both ways, the views that read it, its rules, its history, its SQL |

  The agent works at any level too: "zoom into `orders`" opens the focus for you, and it can render the
  level it needs to check its work.
- **Says what things are at a glance.** One set of visual cues, the same in every perspective and at
  every zoom level:

  | Cue | Means |
  |---|---|
  | key icons | primary key, unique, foreign key, Iceberg identifier field |
  | solid / dashed line | enforced relationship / logical one (always dashed on Iceberg) |
  | crow's foot, ring | many, optional |
  | dashed card | a database view; a double outline for a materialized one |
  | badges | tags and patterns (`scd2`, `fact`, `dimension`), partitioned, sorted |
  | a faint dot on a column | nullable |
  | red / amber marker | a rule fails / a rule warns, with the rule's name on hover |
  | green / amber / faded red | just added / changed / removed, as changes land |
  | a pulsing outline | what the agent is working on right now |
  | a lock | part of the last locked version, unchanged since |
  | area colour | which area a table belongs to, from the whole-schema view down to the card |
- **Makes everything easy to point at.** Pointing is how you direct, so anything you can see can be copied
  as a short reference and pasted into your prompt; the agent resolves it through the MCP:

  | You point at | Reference |
  |---|---|
  | a table, a view, a column | `@orders`, `@current_orders`, `@orders.total` |
  | a key, an index, a relationship | `@orders.fk_orders_customers` |
  | an area, a tag | `@area:billing`, `@tag:scd2` |
  | a rule | `@rule:naming.tables`, `@rule:scd2` |
  | a finding (an inconsistency, a failing rule) | `@finding:14` |
  | a locked version, a change | `@v3`, `@change:42` |
  | what you selected | `@selection` |

  "Make `@tag:dimension` follow `@rule:scd2`", "fix `@finding:14`", "why did `@change:42` drop that
  index?" The agent writes the same references back, and they are clickable in the perspectives.
- **Keeps to the rules.** Set per schema as a collection of rule packs (type defaults, Debezium, SCD, your naming…), as above. The agent sees every rule, and is
  told plainly, with the expected form, when an operation breaks one. Naming, for example:

  ```toml
  [naming]
  tables       = "snake_case"     # or "PascalCase" (TableName), "camelCase" (tableName)
  plural       = true
  foreign_keys = "fk_{table}_{referenced_table}"
  ```

- **Treats views as objects.** Database views carry their definition and know what they read, so a change
  that would break a view is caught.
- **Highlights inconsistencies.** The same column with different types, relationship ends that do not
  match, one kind of data in many types: marked on every table and column, gathered in the Consistency
  perspective, each with a fix the agent can make.
- **Designs CDC targets.** From a MySQL or PostgreSQL schema to Iceberg tables through Debezium: every column mapped by
  the rules, every hazard shown, the Debezium settings written to match ([docs/cdc.md](docs/cdc.md)).
- **Versions as definitions, with or without git.** A locked version is written as one SQL file per
  object, at a path that says where it lives (`<node>/<database>/<schema>/tables/orders.sql`), plus a small
  `.schema-forge/` folder for what SQL cannot say. A plain folder works; in a git repository each lock is also a
  commit and a tag, and a plain folder can join a repository later with its history
  ([docs/versions.md](docs/versions.md)).
- **Exports SQL.** One file per version: the whole schema, or the migration from the last version.
- **Reads what you have.** Import a MySQL or PostgreSQL schema dump, or Iceberg table definitions;
  nothing in them is lost.

## Three targets

One model, three targets. The model holds what each target can express, and the rules and perspectives know the
difference.

| | MySQL | PostgreSQL | Apache Iceberg |
|---|---|---|---|
| **Keys** | primary, unique, foreign, enforced | primary, unique, foreign, enforced | no referential integrity: **identifier fields** mark the key, not enforced (enforced constraints arrive only in format v4) |
| **Relationships** | foreign keys | foreign keys | **logical only:** drawn in the diagram and checked by the rules, never written as constraints |
| **Table parameters** | engine, charset, collation, auto-increment | tablespaces, partitioning, storage options | **partition spec** (identity, bucket, truncate, year/month/day/hour), **sort order**, **table properties** (format version, file format, compression, write modes) |
| **Types** | MySQL types | PostgreSQL types | Iceberg types: decimal, timestamp(tz), uuid, fixed, binary, struct, list, map; v3 adds nanosecond timestamps, variant, geometry, geography; column defaults from v3 |
| **Views** | `CREATE VIEW` | views and materialized views | **versioned views**, one SQL text per engine dialect (Spark, Trino) |
| **Export** | `.sql` | `.sql` | Spark SQL DDL (`USING iceberg`), Trino DDL, or table metadata (schema with field IDs, partition spec, sort order, properties) |

Moving a schema between targets is a conversion the agent and the rules check: from MySQL to Iceberg,
foreign keys become logical relationships and primary keys become identifier fields; types map, and any
type without an equivalent is reported, never dropped.

The model behind it all: [docs/model.md](docs/model.md).

## How it is built

- **One model, one owner.** `schema-forge serve` holds the schema. Every change is an operation from the agent,
  through the MCP, in one queue; it is stored and appears in every perspective at once.
- **Stored in an embedded SurrealDB.** `schema-forge` carries its own database (SurrealDB on SurrealKV, its
  pure-Rust storage engine): schemas, operations and history, versions, findings, standards, pipelines.
  Relationships and view dependencies are a graph it queries directly, and its live queries push every
  change to the perspectives. Nothing to install or run beside `schema-forge`.
- **Definitions on disk.** `schema-forge export` writes, and `schema-forge import` reads, the shareable form: one SQL file
  per object under `<node>/<database>/<schema>/`, and `.schema-forge/` beside them (the model's ids, tags, areas and
  patterns, the rules, custom perspectives, versions, migrations).
- **Rust** throughout where it can be; the perspectives in SuperX's purple theme, their technology still open (below).

| Crate | Job |
|---|---|
| `schema-forge-core` | the schema model, operations, rules, versions |
| `schema-forge-store` | the embedded SurrealDB: storing, querying and live changes |
| `schema-forge-dialects` | reading and writing MySQL, PostgreSQL and Iceberg |
| `schema-forge-mcp` | the MCP the agent works through |
| `schema-forge` | the command: `schema-forge serve`, `schema-forge new`, `schema-forge import`, `schema-forge export` |

## Built on

We build the schema logic; everything else comes from established, pure-Rust libraries. Two choices are
still open (below).

| Need | Library |
|---|---|
| SQL parsing | **sqlparser** (Apache DataFusion): MySQL and PostgreSQL dialects, pure Rust |
| Iceberg | **iceberg** (Apache iceberg-rust, the official crate): table metadata, partition specs, sort orders, catalogs |
| MCP | **rmcp**, the official Rust SDK, over streamable HTTP |
| Server and live push | **tokio**, **axum**, **tower-http** (static files, server-sent events) |
| Storage | **surrealdb**, embedded, on **SurrealKV** (pure Rust) |
| Files and formats | **serde**, **serde_json**, **toml**, **schemars** (JSON Schema for `schema.json` and the MCP tools) |
| Command line | **clap** |
| View dependencies | **petgraph** (dependency order, cycle detection) |
| Version hashes | **blake3** |
| Git | **gix** (gitoxide), pure Rust: history, commits, tags |
| Errors | **thiserror** |
| Tests against real databases | **testcontainers** (PostgreSQL, MySQL) |
| Deploy, later | **sqlx** (PostgreSQL, MySQL), **iceberg** catalogs |

### Open decisions

- **The perspectives (the UI).** A solid, elegant design users like, not a quick UI. Browser perspectives (React Flow) give the
  richest diagrams today; Rust UI (Leptos or Dioxus in the browser; egui, Iced or Slint as a native app)
  keeps one language. Decided before any perspective is built, from a design of the perspectives themselves.
- **PostgreSQL parsing.** sqlparser (pure Rust) is the default; the round-trip tests decide whether it
  reads real `pg_dump` files exactly. `pg_query` (PostgreSQL's own parser) is exact, but links C code, so it
  is not used unless pure Rust cannot do the job.

## Roadmap

1. Import a MySQL or PostgreSQL dump and see it in the diagram, list and definition perspectives; export SQL.
2. Build with the agent: the MCP, the rules, every change live.
3. Iceberg: tables, partitions, sort orders, properties, versioned views; conversion between targets;
   CDC pipelines from MySQL or PostgreSQL through Debezium.
4. Categories and custom perspectives; references to everything.
5. Locked versions as definitions; migrations; git when present (commits, tags, merges); CI checks.
6. **Deploy:** apply a version to a destination database or Iceberg catalog directly, or through the exported SQL file.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT), at your option.
Unless you state otherwise, any contribution you submit for inclusion is dual licensed as above, without any
additional terms or conditions.

`schema-forge` binaries include SurrealDB, whose core is licensed under the Business Source License 1.1 (each release
becomes Apache-2.0 four years after it is published); SurrealKV is Apache-2.0.
