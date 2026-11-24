# The store

Everything SchemaForge keeps lives in **PostgreSQL 18, bundled with the app**: each release carries its platform's
PostgreSQL programs, and the app runs them itself. Nothing to install, nothing to configure.

```
sf_workspace            what the workspace shares: its schemas (by their stable ids) and the saved connections
sf_<schema id, hex>     one database per schema: the cortex's tables and its engine's tables
```

The database is designed first and locked: the tables are the files of the schema folders, one `CREATE TABLE` per file,
every column documented on its line and in the database's own comments (`\d+ cortex.objects` shows them), and no
build creates or changes a table any other way.

| Folder | Namespace | What it holds |
|---|---|---|
| [`schema/cortex/`](../schema/cortex) | `cortex` | what every engine shares: the schema's identity, its object kinds and the parts each may have, namespaces, objects, columns, relationships, subject areas; the shared section layout as tables (table keys, check constraints, indexes, partitionings, sort fields, view queries, sequences, composite types, routines, triggers, scheduled events, verbatim statements); the id counters; the log (turns, operations, row and value changes, locked versions); `rules/` and `enforce_rules.sql` |
| [`schema/workspace/`](../schema/workspace) | `workspace` | the workspace, its schemas, the saved connections (never a secret), their tests |
| `engines/<engine>/schema/` | `engine_<engine>` | the engine's own tables (`engine_mysql.table_options`), each referring to the cortex row it belongs to; its `rules/` |

- **The database enforces it.** Every reference is a foreign key and every value is typed and checked. A rule a
  foreign key cannot state is a view of the rows breaking it (`cortex.broken_parts_only_in_their_kinds`);
  `cortex.enforce_rules` reads which tables each view depends on and puts a deferred constraint trigger on each, so
  PostgreSQL itself refuses a commit that breaks a rule, whoever wrote it. The view is read once per commit, and again
  only after a later write, so a 3,000-row import commits in about 30 ms.
- **The log is the truth.** Every change is an operation of a turn, appended and never edited, with every row and
  value it changed; the current model is written in the same transaction; undo and reject apply the inverses as a new
  turn.
- **Ids.** A part's primary key is the model's own id (`o_orders`). A part the model gives no id is named from its
  parent, a word and a number given once from `id_counters` and never reused (`o_orders.key1`). The schema, the
  workspace and the log are keyed by UUIDv7, issued in increasing order.
- **Order.** A place in a list is a `NUMERIC` order key: one put between two takes their midpoint, so nothing is
  renumbered.
- **Locked, in the files and in the database.** `specs/lock.xml` holds the checksum of every file of the design,
  and the build refuses a change made outside a design session. In the database, the app runs as `sf_service`, which
  reads and writes rows but cannot create, alter or drop anything; only `sf_owner`, which every migration runs as,
  changes the schema; `sf_reader` only reads.
- **Versions per owner.** The cortex, the workspace and each engine version their own tables; every database records
  what it applied, with checksums.

Still to decide before the store is built (`specs/root.xml`, decisions): where the bundled cluster runs and how the app
reaches it (`cluster-scope`), where the pinned programs come from at build and test time (`binaries-source`), and the
Rust driver (`pg-driver`).
