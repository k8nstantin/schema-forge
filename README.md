# Schema Forge (`sf`)

**An ER design tool with many useful perspectives: build your database schema together with your coding
agent, and watch it take shape.**

You prompt the agent. The agent works through Schema Forge's MCP. Every change appears at once on a rich,
live perspective that you both see. When the schema is right, export it for MySQL, PostgreSQL or Apache Iceberg.

```
 you ──prompt──► coding agent ──MCP──► sf ──► live perspectives (you see them, the agent can render them)
                                        │
                                        └──► export   (MySQL, PostgreSQL, Iceberg)
```

## Start

```
cd myproject
sf serve
```

`sf serve` starts Schema Forge, adds its MCP to the project for Claude Code, and opens the perspectives. Then you prompt Claude Code in the same folder: "design an order system; orders are SCD Type 2".

## What it does

- **Builds the schema with the agent.** The agent reads the schema and the rules, then changes it one
  operation at a time: add a table, a column, a relation, a view. Each operation is checked against the
  rules before it applies. You steer by prompt, or point at something in a perspective and say "this one".
- **Shows it, live, from several sides.** Every change lands in every perspective as it happens:

  | Perspective | Shows |
  |---|---|
  | **Diagram** | tables and views as cards, with their relationships |
  | **List** | every table and view with its columns, types and constraints |
  | **Definition** | the SQL definition of what you selected, in your target database |
  | **Categories** | the schema grouped by area or tag |
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
- **Keeps to the rules.** Built-in (naming, keys, indexed foreign keys), patterns such as SCD Type 2, and
  your own rules. The agent sees every rule, and is told plainly when an operation breaks one.
- **Treats views as objects.** Database views carry their definition and know what they read, so a change
  that would break a view is caught.
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

- **One model, one owner.** `sf serve` holds the schema. The agent's operations (through the MCP) and
  your edits (in the perspectives) go through one queue, are saved to `schema.json`, and appear in every perspective at
  once.
- **Plain files, in git.** `schema.json` (the draft), `versions/` (locked versions, never edited),
  `sf.toml` and `rules/` (the rules), `perspectives/` (custom perspectives), `export/` (the SQL).
- **Rust** throughout where it can be; the perspectives in SuperX's purple theme, their technology still open (below).

| Crate | Job |
|---|---|
| `sf-core` | the schema model, operations, rules, versions |
| `sf-dialects` | reading and writing MySQL, PostgreSQL and Iceberg |
| `sf-mcp` | the MCP the agent works through |
| `sf` | the command: `sf serve`, `sf import`, `sf export` |

## Built on

We build the schema logic; everything else comes from established, pure-Rust libraries. Two choices are
still open (below).

| Need | Library |
|---|---|
| SQL parsing | **sqlparser** (Apache DataFusion): MySQL and PostgreSQL dialects, pure Rust |
| Iceberg | **iceberg** (Apache iceberg-rust, the official crate): table metadata, partition specs, sort orders, catalogs |
| MCP | **rmcp**, the official Rust SDK, over streamable HTTP |
| Server and live push | **tokio**, **axum**, **tower-http** (static files, server-sent events) |
| Files and formats | **serde**, **serde_json**, **toml**, **schemars** (JSON Schema for `schema.json` and the MCP tools) |
| Command line | **clap** |
| Watching `schema.json` | **notify** |
| View dependencies | **petgraph** (dependency order, cycle detection) |
| Version hashes | **blake3** |
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
3. Iceberg: tables, partitions, sort orders, properties, versioned views; conversion between targets.
4. Categories and custom perspectives; editing by hand.
5. Locked versions and migrations.
6. **Deploy:** apply a version to a destination database or Iceberg catalog directly, or through the exported SQL file.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT), at your option.
Unless you state otherwise, any contribution you submit for inclusion is dual licensed as above, without any
additional terms or conditions.
