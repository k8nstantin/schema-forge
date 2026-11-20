# The store

Everything `schema-forge` keeps lives in one embedded SurrealDB, on SurrealKV (pure Rust), inside the
workspace: `~/.schema-forge/workspaces/<name>/store/`. Nothing runs beside `schema-forge`; the definitions
folders (docs/versions.md) are the shareable file form of what is in here.

## Principles

1. **One writer.** `schema-forge serve` owns the store. Other commands (`schema-forge import`, `export`,
   `check`) go through the running server when there is one, and open the store themselves only when there
   is not (a lock file prevents two writers).
2. **The log is the truth; the current model is kept beside it.** Every change is an `operation`, appended
   and never edited. The schema's objects are records kept up to date by each operation, so reading the
   current model is a plain query, and replaying the log rebuilds it exactly.
3. **Objects are records, relationships are edges.** Tables, columns, views, keys are records; what links
   them (references, what a view reads, partitions) are graph edges, so "what depends on this" is one query.
4. **Ids are the model's readable ids,** inside the schema: a record id is the pair (schema, id), e.g.
   `object:['orders', 't_orders']`. The same ids appear in `.schema-forge/model.json`.
5. **Live queries feed the perspectives:** each operation that lands is pushed to every open perspective.
6. **The store has its own format version,** upgraded in place when a newer `schema-forge` opens it.

## Records

### Workspace and schemas

| Table | Holds |
|---|---|
| `meta` | the store's format version, created, upgraded |
| `schema` | name, type (`mysql`, `postgres`, `iceberg`), its rule collection (ordered packs and overrides), the linked definitions folder, created, last opened |
| `pipeline` | source schema, target schema, kind (`debezium`), created |

### The model

| Table | Holds |
|---|---|
| `object` | every schema object: its schema, readable id, kind (`namespace`, `area`, `table`, `column`, `view`, `key`, `index`, `check`, `sequence`, `type`, `kept`), name, and its fields as in docs/model.md (`type`, `nullable`, `options`, …), position among its siblings |
| `layout` | where each card sits, per schema; apart from the model, so moving a card never changes it |

**Edges between objects:**

| Edge | From → to | Carries |
|---|---|---|
| `has` | table → column, table → key, table → index, namespace → table | order |
| `references` | table → table (a relationship) | columns both sides, enforced or logical, on delete/update, name |
| `reads` | view → table or view | found by parsing the view's definition |
| `partition_of` | table → table | bounds (designed partitions only) |
| `in_area` | table or view → area | |
| `names` | kept statement → object | objects a kept statement refers to |
| `maps` | source column → target column (a pipeline) | the rule that decided it, the Debezium type in between |

So "what breaks if `orders.total` is dropped" is a walk from that column along `has`, `references`,
`reads`, `names` and `maps`.

### Changes and history

| Table | Holds |
|---|---|
| `turn` | one agent turn: its schema, when it started and ended, the prompt's summary as the agent gives it, accepted, rejected or undone |
| `operation` | one change, appended, never edited: its schema, turn, sequence number, kind (`add_table`, …), the change, its inverse (for undo), who (`agent`, `import`, `file`), when, state (`applied`, `rejected`, `undone`) |
| `version` | a locked version: schema, number, hash, when, the full model at that version, each definition file's hash, the git commit and tag when there is one |

`@change:42` is operation 42 of the schema; `@turn:12` its twelfth turn; `@v3` its third version.

### Standards

| Table | Holds |
|---|---|
| `pack` | a rule pack: name, the types it applies to, its rules and settings, built in or yours, its version |
| `template` | a saved collection: name, type, packs in order, overrides |

Built-in packs are shipped with `schema-forge` and loaded into the store at start; yours are also files in
`~/.schema-forge/standards/` (so they can be shared), and the store follows those files.

### What you see and point at

| Table | Holds |
|---|---|
| `finding` | an inconsistency or a failing rule: its schema, number (`@finding:14`), kind, rule, objects, message, suggested fix, open or resolved |
| `note` | a pinned note: the object, the text, who, when, done when the agent acted on it (and in which turn) |
| `perspective` | a saved custom perspective: tables, columns, grouping, colours |
| `view_state` | per open perspective: which one, what is in view, zoom level, selection (`@perspective`, `@selection`) |

## How it is used

- **An operation lands:** in one transaction, the `operation` is appended and the `object` records and
  edges it touches are changed; findings for the touched objects are re-checked.
- **A perspective opens:** it reads the current model, then subscribes with a live query to the schema's
  operations, findings and notes, and applies each as it arrives.
- **Undo a turn:** the turn's operations' inverses are applied, newest first, as new operations (nothing is
  deleted from the log).
- **Lock a version:** the current model is written into `version` with its hash, then out to the
  definitions folder (and git).
- **Export and import:** the store's model and the definitions folder convert both ways without loss;
  the round-trip tests prove it.

## Size

A large schema (thousands of tables, tens of thousands of columns) is tens of thousands of records and a
few times as many edges; the operation log grows by one record per change. Both stay small for SurrealKV,
and nothing is ever loaded all at once except the current model of the schema you are looking at.
