# The owner template

**Modularity and yet coherence.** Every engine and every feature brings its own tables, in its own namespace, versioned
on its own, and never changes another owner's; every one of them is built the same way, refers to the cortex by
foreign keys, and is enforced by the same database. This folder is a complete owner, `example`, to copy.

```
engines/<id>/            an engine (features/<id>/ for a feature: insight, semantic, rules, pipelines)
  owner.toml             its id, kind, namespace, newest version and the cortex version it needs
  schema/
    <table>.sql          one CREATE TABLE per file, named after its table, in the namespace engine_<id> (a feature: <id>)
    rules/<rule>.sql     one view per rule, broken_<rule>: the rows breaking it
    migrations/          every version after the first: <version>_<name>.sql; and 1_tables.sql once version 2 exists
```

## The five shapes

Every table an owner needs is one of these. Pick the shape before naming a column.

| Shape | When | Its id | The example |
|---|---|---|---|
| 1. Options of a cortex part | what the engine says of a table, a column, a key... beyond the cortex; at most one row per part | the part's own id, a foreign key | [`table_options.sql`](schema/table_options.sql) |
| 2. An ordered list | many things per part, in order | `<parent>.<word><n>`, n from `cortex.id_counters` | [`column_codecs.sql`](schema/column_codecs.sql) |
| 3. A kind only this engine has | an object the cortex has no kind for (a pool, a tablespace) | the object's id: the object is a `cortex.objects` row of a kind the engine declares | [`storage_pools.sql`](schema/storage_pools.sql) |
| 4. Open-ended properties | only where the engine itself lets anyone name a key (Iceberg's table properties) | `<parent>.<word><n>` | [`table_properties.sql`](schema/table_properties.sql) |
| 5. A tree | nested things (fields of a struct of structs) | `<parent>.<word><n>`, a `parent` column referring to the same table | [`nested_fields.sql`](schema/nested_fields.sql) |

A value the engine names belongs in a typed column of shape 1, never in shape 4: shape 4 is for keys nobody can list.

## Every file, every column

- A header line `-- <namespace>.<table>: <what one row is>. Owner: <id>.`, then any lines more.
- Every column on its own line, typed (`TEXT`, `INTEGER`, `BIGINT`, `NUMERIC`, `BOOLEAN`, `UUID`, `TIMESTAMPTZ`,
  `JSONB`), constrained, and commented: what it holds, and what `NULL` means when it may be null.
- The `COMMENT ON` statements below the table are written from those comments by
  `python3 tools/schema_comments.py --write`; the check refuses a file where they differ, so the database documents
  itself (`\d+ engine_example.table_options`).
- Every reference is a foreign key, with `ON DELETE CASCADE` when the row means nothing without its parent.
- An order is a `NUMERIC` order key (`position`), unique within its list.
- A number in an id comes from `cortex.id_counters` and is never given twice; the rule `ids-within-their-counters` lists
  every numbered table of the owner.

## Rules

A rule a foreign key cannot state is a view, `broken_<rule>`, listing the rows that break it, one file each in `rules/`.
`cortex.enforce_rules('<namespace>')` puts the triggers on every table the view reads; nothing else is written. Every
owner needs at least:

- that its options belong to parts of the right kind ([`table-options-on-tables`](schema/rules/table-options-on-tables.sql));
- that its own kinds' rows are objects of that kind ([`pools-of-their-kind`](schema/rules/pools-of-their-kind.sql));
- that a tree stays within its parent ([`nested-fields-in-their-column`](schema/rules/nested-fields-in-their-column.sql));
- that its numbered ids came from their counters ([`ids-within-their-counters`](schema/rules/ids-within-their-counters.sql)).

## Versions

- **Version 1** is the table files and the rules. Until version 2 exists, nothing else is needed.
- **Every change adds.** A new table, a column that may be null or has a default, a rule, an index: one version.
- **A rename or a removal takes two versions**, shipped in different releases: the first adds the new and copies the
  data ([`2_compaction_policy_add.sql`](schema/migrations/2_compaction_policy_add.sql)), the later one removes the old
  ([`3_compaction_policy_drop_old.sql`](schema/migrations/3_compaction_policy_drop_old.sql)).
- **The table files always show the newest shape**, so the design session that writes version 2 first freezes version 1
  as [`migrations/1_tables.sql`](schema/migrations/1_tables.sql): the files and rules exactly as they shipped, never
  edited again.
- **A column a migration adds is written last** in its table file, where PostgreSQL puts it.
- **Proved, not hoped:** applying versions 1 to 3 of this folder to an empty database gives exactly what its table files
  and rules give (checked on PostgreSQL 18 with `pg_dump --schema-only`); every release proves it for every owner, and
  upgrades a database of every earlier version.
- A shipped version is never edited: its checksum, kept in every database that applied it, refuses it.
