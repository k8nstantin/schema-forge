# The store

Everything `schema-forge` keeps lives in one embedded **redb** database (pure Rust, one file, ACID
transactions), inside the workspace: `~/.schema-forge/workspaces/<name>/store.redb`. Nothing runs beside
`schema-forge`; the definitions folders (docs/versions.md) are the shareable file form of what is in here.

## Principles

1. **One writer.** `schema-forge serve` owns the store. Other commands (`schema-forge import`, `export`,
   `check`) go through the running server when there is one, and open the store themselves only when there
   is not (redb allows one writer; a second is refused, never corrupted).
2. **The log is the truth; the current model is kept beside it.** Every change is an `operation`, appended
   and never edited. The schema's objects are records kept up to date in the same transaction, so reading
   the current model is a range read, and replaying the log rebuilds it exactly.
3. **Records by readable id.** Keys are text, `<schema>/<id>` (`orders/t_orders`), so a schema's records sit
   together and one range read loads them.
4. **Values are JSON**, the same JSON as the model's file form, so nothing is translated twice and a record
   can always be read by eye.
5. **The graph is computed, not stored.** Relationships, what views read, partitions and pipeline mappings
   are in the model already; "what depends on this" is a walk over the loaded model, done in Rust.
6. **Live changes are announced in-process.** The one writer broadcasts each operation as it commits;
   every open perspective subscribed to that schema applies it.
7. **The store has its own format version,** upgraded in place when a newer `schema-forge` opens it.

## Tables

Each is a redb table of text keys to JSON values.

| Table | Key | Value |
|---|---|---|
| `meta` | `format` | the store's format version |
| `schemas` | `<schema>` | name, type, rule collection (ordered packs and overrides), linked definitions folder, created, last opened |
| `objects` | `<schema>/<id>` | one top-level object of the model: a namespace, area, table (with its columns, keys, checks, indexes, options), relationship, view, sequence, type or kept statement |
| `layout` | `<schema>/<id>` | where a card sits; apart from the model, so moving a card never changes it |
| `operations` | `<schema>/<sequence>` | one change, appended, never edited: turn, kind (`add_table`, …), the change, its inverse (for undo), who (`agent`, `import`, `file`), when, state (`applied`, `rejected`, `undone`) |
| `turns` | `<schema>/<n>` | one agent turn: when it started and ended, the prompt's summary as the agent gives it, accepted, rejected or undone |
| `versions` | `<schema>/<n>` | a locked version: number, hash, when, the full model, each definition file's hash, the git commit and tag when there is one |
| `pipelines` | `<pipeline>` | source schema, target schema, kind (`debezium`), each column's mapping and the rule that decided it |
| `packs`, `templates` | `<name>` | rule packs and saved collections (built in ones loaded at start; yours also files in `~/.schema-forge/standards/`) |
| `findings` | `<schema>/<n>` | an inconsistency or failing rule: kind, rule, objects, message, suggested fix, open or resolved |
| `notes` | `<schema>/<n>` | a pinned note: object, text, when, done in which turn |
| `perspectives` | `<schema>/<name>` | a saved custom perspective |

Sequence numbers are written zero-padded (`orders/000000000042`) so keys sort in order.

## How it is used

- **An operation lands:** in one write transaction, the operation is appended and the object records it
  touches are rewritten; on commit it is broadcast. Findings for the touched objects are re-checked.
- **A perspective opens:** it reads the schema's objects (one range read), then subscribes to the
  broadcast and applies each operation as it arrives.
- **Undo a turn:** the turn's operations' inverses are applied, newest first, as new operations (nothing is
  deleted from the log).
- **Lock a version:** the current model is written into `versions` with its hash, then out to the
  definitions folder (and git).
- **Export and import:** the store's model and the definitions folder convert both ways without loss; the
  round-trip tests prove it.

## Size

A large schema (thousands of tables) is thousands of records of a few kilobytes; a change rewrites only the
records it touches. Loading a schema's model is one range read, and the graph walk runs in memory.
