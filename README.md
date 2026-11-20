# Schema Forge (`sf`)

A desktop tool to design relational schemas with an agent and a visual canvas, working on the same file.
It reads MySQL and PostgreSQL schema dumps and writes the same formats back. Version 1 has no database
connections: you run the output yourself with `psql` or `mysql`.

## Workflow

1. **Import** a schema dump: `pg_dump --schema-only` or `mysqldump --no-data` (a full dump works; its data
   statements are skipped and counted).
2. **Design** on the canvas and with the agent, live, on the same draft.
3. **Review** the draft against the last locked version: the diff, the generated SQL, destructive changes
   (dropped tables or columns, narrowed types, removed keys) flagged.
4. **Lock** the draft as version N, with its content hash. A locked version never changes; editing starts N+1.
5. **Generate** the full schema file for PostgreSQL or MySQL, and the migration from version N−1 to N.

## One file, one owner

```
 you (canvas) ─┐
               ├─► operations ─► core model (Rust, one owner) ─► schema.json
 agent (chat) ─┘   add_table, add_column,          │
                   relate, rename, drop …          └─► event ─► canvas redraws live
```

- Every change, yours or the agent's, is a small operation through one queue: no overwrites.
- The canvas shows each change as it lands: new in green, changed in amber, removed as a faded red outline.
- The agent's changes in a turn arrive as one group, accepted or rejected whole or one at a time; undo goes
  one agent turn at a time. An operation log is kept beside the file.
- `schema.json` is watched: a change made outside the app (by hand, git, or another agent such as Claude
  Code) is reloaded and highlighted the same way.
- The agent never generates or applies anything on its own; it only changes the draft.

## Project files (shared through git)

```
myproject/
  schema.json                    the draft: tables, columns, types, keys, indexes, relations, comments
  layout.json                    canvas positions, apart so moving a box never touches the schema
  operations.jsonl               every operation, who made it (you, the agent, the file) and when
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
| `sf-core` | the model, the JSON files and their format version, validation, operations, versions, hashes, diffs |
| `sf-dialects` | import and generation for PostgreSQL and MySQL: a pre-pass sorts dump statements, sqlparser-rs parses DDL; migration SQL |
| `sf-agent` | the Claude API with tools that apply operations to the draft |
| `sf` (cli) | `sf import`, `sf lock`, `sf diff`, `sf generate`, for scripts and CI |
| `app` (later) | Tauri 2, React and React Flow: the canvas and the agent chat, in SuperX's purple (swindex) theme |

## Milestones

1. `sf-core` and `sf-dialects` with round-trip tests on real dumps, through the CLI alone.
2. The canvas: view and edit an imported schema, save, generate.
3. The agent panel: live operations on the shared draft.
4. Lock, diffs and migration SQL.
5. Converting between dialects; then SQLite and Iceberg (Spark/Trino DDL, iceberg-rust catalogs).

Not in version 1: database connections, applying changes, multiple users.

## Build

`cargo build` builds the workspace; `sf` is the command-line tool.
