# Schema Forge (`sf`)

Design relational schemas by prompting your coding agent, and watch the schema take shape on a live canvas.
The agent works through Schema Forge's MCP server, under rules the project sets (SCD Type 2, naming, keys,
your own). You and the agent see the same canvas at the same time.

- **Agent first:** the first target is Claude Code. You prompt it; it calls `sf` tools; every change is
  checked against the rules and drawn as it lands.
- **Databases:** MySQL and PostgreSQL. Schema Forge reads their schema dumps and writes the same formats
  back. Version 1 has no database connections: you run the output with `psql` or `mysql`.

## Principles

- **We design together.** The user and the agent are partners on one schema: the user directs by prompt
  and by hand, the agent proposes and builds, and both see every change as it happens. Neither works blind,
  and nothing changes without the user seeing it.
- **One view, from day one.** The live canvas ships in the first milestone, not after the engine.
- **Rich graphics.** The canvas is the product's face, not a debug view (see [The canvas](#the-canvas)).

## Workflow

1. **Import** an existing schema dump (`pg_dump --schema-only`, `mysqldump --no-data`; a full dump works,
   its data statements are skipped and counted), or start empty.
2. **Prompt** Claude Code: "add customers and orders, orders are SCD Type 2". The agent reads the schema and
   the rules through the MCP, then applies operations.
3. **Watch** the canvas: each operation appears as it lands. You can also edit on the canvas yourself.
4. **Review** the draft against the last locked version: the diff, the generated SQL, every rule satisfied,
   destructive changes (dropped tables or columns, narrowed types, removed keys) flagged.
5. **Lock** the draft as version N, with its content hash. A locked version never changes; editing starts N+1.
6. **Generate** the full schema file for PostgreSQL or MySQL, and the migration from version N−1 to N.

## One model, one owner, two viewers

```
 Claude Code ── MCP tools ──┐
                            ├─► operations ─► sf (one owner) ─► schema.json + operations.jsonl
 you, on the canvas ────────┘                     │
                                                  ├─► live canvas, seen by you
                                                  └─► describe / render, seen by the agent
```

- **`sf serve`** runs the owner: one local process that holds the model, serves the MCP to Claude Code, and
  serves the live canvas in the browser at `localhost`. Every change, the agent's or yours, is a small
  operation through one queue: no overwrites.
- **Live view:** the canvas shows each change as it lands: new in green, changed in amber, removed as a
  faded red outline. The agent's changes in a turn form one group, accepted or rejected whole or one at a
  time; undo goes one agent turn at a time.
- **The agent sees it too:** `describe` returns the schema as compact text, and `render` returns the same
  canvas as an image (or a Mermaid diagram), so the agent checks its work the way you do.
- **The file stays the truth:** the model is saved to `schema.json` as it changes, with every operation
  logged (who: the agent, you, or the file; when). A change made to the file outside `sf` is reloaded,
  validated against the rules and highlighted.
- The agent only changes the draft: it never locks or generates unless you ask it to.

## The canvas

Served by `sf serve` in the browser, in SuperX's purple (swindex) theme, light and dark. Rich from the
first release:

- **Tables as cards:** every column with its type, nullability and default; key icons for primary, foreign
  and unique keys; tags (e.g. `scd2`, `fact`, `dimension`) as badges.
- **Relationships drawn as they are:** crow's-foot cardinality, labelled with the columns they join, routed
  around the cards.
- **Rules on the canvas:** a table that fails a rule shows it on the card, with the rule's name; a pattern
  such as SCD Type 2 shows its validity columns and keys marked as the pattern's.
- **Areas:** tables grouped into named domains (billing, catalog, …), each its own colour, folded or open.
- **Layout:** automatic layout (ELK) for an imported or agent-built schema, hand placement kept once you
  move a card; minimap, zoom, search, focus on one table and its neighbours.
- **Designing together, visibly:** the agent's changes animate in as they land (new in green, changed in
  amber, removed as a faded red outline); while it works, the canvas shows what it is working on; the
  user's selection is readable by the agent through `describe`, so "this table" means the same to both.
- **Panels:** the selected table's full detail, its SQL in the chosen dialect, the rule checks, and the
  history of who changed it.

## The MCP: how agents work with Schema Forge

`sf serve` exposes an MCP server (Rust, the official `rmcp` SDK). Claude Code connects to it with one line
in its MCP settings.

| Tool | What it does |
|---|---|
| `guide` | the workflow and the project's rules, in words the agent follows |
| `describe` | the schema, or one table, as compact text |
| `render` | the canvas, or one area of it, as an image or a Mermaid diagram |
| `rules` | every active rule, and which tables each one applies to |
| `check` | every rule against the draft: what passes, what fails, and why |
| `add_table`, `add_column`, `relate`, `rename`, `alter_column`, `drop`, `index`, `comment` | one operation each, validated before it applies |
| `apply_rule` | make a table satisfy a rule, e.g. give `orders` its SCD Type 2 columns and keys |
| `diff` | the draft against the last locked version |
| `lock`, `generate` | only when the user asks |

An operation that breaks a rule is refused with the rule's name and the reason, so the agent can fix its
proposal before anything changes.

## Rules

Rules live in the project (`sf.toml` and `rules/`), are checked by `sf-core` on every operation from any
source, and are listed to the agent through `guide` and `rules`.

**Built in:** `snake_case` names, plural table names, every table has a primary key, every foreign key is
indexed, types allowed per dialect, comments required on tables, destructive changes need an explicit flag,
nothing under `versions/` is ever edited. Each can be turned on, off, or configured.

**Patterns**, for example **SCD Type 2** on a table:
- a surrogate primary key, and the business key it versions;
- `valid_from` and `valid_to` (the current row has an open `valid_to`);
- unique (business key, `valid_from`);
- no column that would need an in-place update to keep history.

`apply_rule scd2 orders` adds what is missing; `check` reports what does not fit.

**Custom rules:** your own, declared in `rules/*.toml`, in the same form as the built-in ones: which tables
they apply to (by name, tag or pattern), which columns, keys and types they require or forbid, and the
message the agent sees when an operation breaks them.

## Project files (shared through git)

```
myproject/
  sf.toml                        dialect, active rules and their settings
  rules/                         custom rules
  schema.json                    the draft: tables, columns, types, keys, indexes, relations, comments, tags
  layout.json                    canvas positions, apart so moving a box never touches the schema
  operations.jsonl               every operation, who made it and when
  versions/0001.json             locked versions, never edited, each with its hash
  generated/0001_postgres.sql    the full schema and the migration for each version and dialect
  kept/                          statements carried through unparsed (see below)
```

## Reading real dumps, losing nothing

Dumps hold more than `CREATE TABLE`: `SET` lines, sequences, `ALTER TABLE ONLY … ADD CONSTRAINT`,
`COMMENT ON`, owners and grants, views, functions, triggers, extensions; MySQL's `/*!40101 … */`
version comments, `LOCK TABLES`, engines, charsets and `AUTO_INCREMENT`.

- Tables, columns, keys, indexes, comments and sequences become the model, which the canvas and the agent
  edit.
- Everything else is kept verbatim, in order, and written back unchanged.
- A statement that cannot be parsed is kept verbatim and listed. Every import prints a report: statements
  parsed, kept, and skipped as data, with counts that add up to the whole file.
- **The proof is the round trip:** import a dump, generate it with no edits, and compare. Tests run this on
  real `pg_dump` and `mysqldump` files; CI loads the output into throwaway PostgreSQL and MySQL containers
  to prove it is valid SQL.

## Workspace

| Crate | Job |
|---|---|
| `sf-core` | the model, the JSON files and their format version, operations, rules and their checks, versions, hashes, diffs |
| `sf-dialects` | import and generation for PostgreSQL and MySQL: a pre-pass sorts dump statements, sqlparser-rs parses DDL; migration SQL |
| `sf-mcp` | the MCP server: the tools above, over the owner's operation queue |
| `sf` (cli) | `sf serve`, `sf import`, `sf check`, `sf lock`, `sf diff`, `sf generate` |
| `canvas` | the live canvas: React and React Flow, served by `sf serve`, in SuperX's purple (swindex) theme; a Tauri desktop shell later |

## Milestones

1. **The engine and the view:** `sf-core` and `sf-dialects` with round-trip tests on real dumps, and
   `sf serve` showing an imported schema on the rich canvas: cards, relationships, areas, layout.
2. **Designing together:** the MCP and the rules (built-ins and SCD Type 2); Claude Code builds by prompt
   while the canvas shows each change as it lands; `describe`, `render`, `check`, shared selection.
3. Editing on the canvas by hand, through the same operation queue as the agent.
4. Lock, diffs and migration SQL.
5. Custom rules in `rules/`; then converting between dialects, SQLite and Iceberg.

Not in version 1: database connections, applying changes, multiple users.

## To think through

- **Custom rules:** how far declarations go before a rule needs code (a small embedded language, or WASM),
  and how rule packs are shared between projects.
- **Rules that span tables:** e.g. every fact table references only SCD Type 2 dimensions by surrogate key.
- **Seeing together:** beyond shared selection, how the agent points at what it means on the canvas
  (highlights, notes pinned to a table).
- **Several agents at once**, or an agent and a teammate, on one project.

## Build

`cargo build` builds the workspace; `sf` is the command-line tool.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT), at your option.
Unless you state otherwise, any contribution you submit for inclusion is dual licensed as above, without any
additional terms or conditions.
