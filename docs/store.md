# The store

Everything Schema Forge keeps lives in **SQLite**, inside the workspace folder:

```
~/.schema-forge/workspaces/<name>/
  workspace.db          what the workspace shares: its schemas (by their stable ids) and the saved connections
  schemas/<name>.db     one file per schema: the cortex's tables and its engine's tables
```

The database is designed first and locked: the tables are the files of the schema folders, one `CREATE TABLE` per file,
every column documented, and no build creates or changes a table any other way.

| Folder | Owner | What it holds |
|---|---|---|
| [`schema/cortex/`](../schema/cortex) | the cortex | what every engine shares: the schema, its kinds, namespaces, objects, columns and links; the shared section layout as tables (keys, checks, indexes, partitions, order, queries, sequences, types, routines, triggers, events, what is kept as written); the log (turns, operations, row and value changes, versions); `integrity.sql` |
| [`schema/workspace/`](../schema/workspace) | the workspace | the workspace, its schemas, the saved connections (never a secret), their tests |
| `engines/<engine>/schema/` | each engine | the engine's own tables, `<engine>__<name>`, each referring to the cortex row it belongs to; its `integrity.sql` |

- **The database enforces it.** Tables are `STRICT`; every reference is a foreign key; what a foreign key cannot say is
  a query of an `integrity.sql`, run before every commit.
- **The log is the truth.** Every change is an operation of a turn, appended and never edited, with every row and
  value it changed; the current model is written in the same transaction; undo and reject apply the inverses as a new
  turn.
- **Ids.** A part's primary key is the model's own id (`o_orders`); a part the model gives none is named from its
  parent and its place (`o_orders.key1`); the schema, the workspace and the log are keyed by UUIDv7, issued in
  increasing order.
- **Versions per owner.** The cortex, the workspace and each engine version their own tables; every file records what
  it applied, with checksums.

The decisions, with their dates, are in [`specs/root.xml`](../specs/root.xml); the order the store is built in is its
sequence.
