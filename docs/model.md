# The schema model

The one structure Schema Forge is built on. The agent's operations change it, every perspective shows it,
and every import and export reads or writes it. This document is the design to agree before any code.

## Principles

1. **One project, one target.** A project is designed for MySQL, PostgreSQL or Iceberg. Types, options and
   rules are that target's own, written the way that target writes them. Moving to another target is a
   conversion that makes a new project, with a report (see [Conversion](#conversion)).
2. **Nothing is lost.** Whatever the model does not describe is kept verbatim and written back in its
   place. Every type, option and definition keeps its exact form.
3. **Every object has an identity.** Each table, column, key, index, relationship, view and sequence has a
   stable, readable `id` besides its name (see [Ids](#ids)). Renaming changes the name, not the identity, so a migration renames
   instead of dropping and recreating, and data survives.
4. **Facts only.** The model holds what the schema is. Layout, perspectives, rules and history live in
   their own files.
5. **Order is meaning.** Column order, statement order and view dependency order are kept and respected.

## The schema file

The model lives in `schema-forge`'s embedded SurrealDB while you work; `schema.json` is the same model written as a
file, for git and for sharing (`schema-forge export`, `schema-forge import`).

```json
{
  "format": 1,
  "target": "postgres",
  "namespaces": [ … ],
  "areas": [ … ],
  "tables": [ … ],
  "relationships": [ … ],
  "views": [ … ],
  "sequences": [ … ],
  "types": [ … ],
  "kept": [ … ]
}
```

`format` is the version of this file format; a newer `schema-forge` upgrades older files and never writes an older
format. `target` is `mysql`, `postgres` or `iceberg`.

## Ids

Readable, made once from the object's kind and name when it is created, and never changed:

| Kind | Example |
|---|---|
| namespace, area | `n_public`, `a_billing` |
| table, view | `t_orders`, `v_current_orders` |
| column | `c_orders_total` |
| key, index, check | `u_orders_version`, `i_orders_customer`, `k_orders_total_positive` |
| relationship | `r_orders_customer` |
| sequence, type | `s_orders_seq`, `y_order_status` |

- An id that is already taken gets a number: `t_orders_2`.
- A rename keeps the id, so after renaming `orders` to `sales` the table is still `t_orders`: the id is its
  identity, not its name. Every perspective, the agent and the generated SQL use the name.
- Everything refers to other objects by id: keys, indexes, relationships, views' `reads`, partition and sort
  fields, patterns. Renames then never break a reference.

## References

How you point the agent at anything: you never edit the schema, so a reference is how an instruction says
what it means. Copied from any perspective with one action, pasted into the prompt.

| Object | Reference |
|---|---|
| table, view | `@orders` (`@billing.orders` when the name is in more than one namespace) |
| column | `@orders.total` |
| key, index, relationship | `@orders.fk_orders_customers` |
| area, tag | `@area:billing`, `@tag:scd2` |
| rule, pattern | `@rule:naming.tables`, `@rule:scd2` |
| finding | `@finding:14` (an inconsistency or a failing rule, numbered while it lasts) |
| locked version, change | `@v3`, `@change:42` (a line of `operations.jsonl`) |
| the current selection | `@selection` |

The agent's `describe` and every operation take references as well as ids. A reference is resolved to the
id at the moment it is used, so `@orders` keeps meaning the same table only until it is renamed; the id
lasts.

## Objects

### Namespace

Where objects live: a PostgreSQL schema (`public`, `billing`), a MySQL database, an Iceberg namespace
(which can be nested: `analytics.sales`).

| Field | |
|---|---|
| `id`, `name` | `name` is a path for Iceberg (`["analytics", "sales"]`) |
| `comment` | |

### Table

| Field | |
|---|---|
| `id`, `namespace`, `name` | |
| `partition_of` | PostgreSQL, a designed partition only: the parent table and its bounds (`FOR VALUES …`, or `DEFAULT`) |
| `comment`, `tags`, `area` | `tags` are free words (`fact`, `dimension`); `area` groups tables in the perspectives |
| `columns` | ordered |
| `primary_key` | `{ name, columns }`; Iceberg: see `identifier_fields` |
| `uniques` | `[{ id, name, columns, nulls_distinct }]` (`nulls_distinct`: PostgreSQL 15+) |
| `checks` | `[{ id, name, expression }]`, the expression kept as written |
| `indexes` | see [Index](#index) |
| `patterns` | patterns the table follows, with their settings, e.g. `{ "scd2": { "business_key": ["customer_no"] } }` |
| `options` | the target's own, below |

**Options by target:**

| MySQL | PostgreSQL | Iceberg |
|---|---|---|
| `engine`, `charset`, `collation`, `row_format`, `auto_increment` (next value), `partitioning` (kept as written) | `tablespace`, `unlogged`, `partition_by` (`range`/`list`/`hash`, keys), `partition_policy` (`interval` such as `1 day` or `1 month`, `retention`, `premake`, `managed_by`: `pg_partman`, the application, or `schema-forge`; and any imported `series`: interval, first and last bound, count, the statements kept verbatim), `inherits`, `storage` parameters | `format_version` (1–3), `identifier_fields`, `partition_spec`, `sort_order`, `properties`, `location` |

Iceberg's own parts:

- **`identifier_fields`:** the columns that identify a row. Required columns, not float or double, not
  inside a list or map. Iceberg does not enforce them.
- **`partition_spec`:** `[{ source, transform, name }]`, where `transform` is `identity`, `bucket[N]`,
  `truncate[W]`, `year`, `month`, `day`, `hour` or `void`.
- **`sort_order`:** `[{ source, transform, direction, nulls }]`, `direction` `asc`/`desc`, `nulls`
  `first`/`last`.
- **`properties`:** a map of Iceberg table properties (`write.format.default`,
  `write.parquet.compression-codec`, `write.delete.mode`, …), kept as given.

### Column

| Field | |
|---|---|
| `id`, `name` | |
| `type` | the target's type, structured (below) |
| `nullable` | Iceberg calls it `required` (the opposite); the model stores `nullable` for all |
| `default` | expression, kept as written; Iceberg (v3): `initial_default` and `write_default` |
| `generated` | `{ expression, stored }`, MySQL and PostgreSQL generated columns |
| `identity` | PostgreSQL `GENERATED ALWAYS/BY DEFAULT AS IDENTITY` with its options; MySQL `AUTO_INCREMENT` |
| `collation` | MySQL, PostgreSQL |
| `comment` | Iceberg calls it `doc` |
| `field_id` | Iceberg only: the column's permanent number, assigned once, never reused |

### Types

A type is stored the way the target spells it, as structure rather than text, so it can be shown,
checked and converted:

```json
{ "name": "varchar", "length": 255 }
{ "name": "numeric", "precision": 12, "scale": 2 }
{ "name": "timestamp", "with_time_zone": true, "precision": 6 }
{ "name": "enum", "values": ["new", "paid", "shipped"] }                      // MySQL, inline
{ "name": "user", "type": "order_status" }                                    // PostgreSQL, see Types below
{ "name": "array", "of": { "name": "text" } }                                 // PostgreSQL
{ "name": "struct", "fields": [ { "field_id": 12, "name": "city", "nullable": true, "type": { "name": "string" } } ] }   // Iceberg
{ "name": "list", "element_id": 13, "element_nullable": false, "of": { "name": "long" } }  // Iceberg
```

Only the target's real types are accepted; anything the parser reads but the model does not know is kept
as `{ "name": "verbatim", "text": "…" }` and written back exactly.

**PostgreSQL user-defined types** live in `types`: `enum` (values, in order), `domain` (base type,
default, not null, checks) and `composite` (fields). Other kinds (ranges, base types) are kept verbatim.

### Index

| Field | |
|---|---|
| `id`, `name`, `unique` | |
| `parts` | `[{ column or expression, direction, nulls, length }]` (`length`: MySQL prefix indexes) |
| `method` | PostgreSQL `btree`/`hash`/`gin`/`gist`/`brin`/`spgist`; MySQL `btree`/`hash`/`fulltext`/`spatial` |
| `include`, `where` | PostgreSQL covering and partial indexes |

Iceberg has no indexes; its sort order and partition spec do that work.

### Relationship

One concept, two strengths:

| Field | |
|---|---|
| `id`, `name` | |
| `from` | `{ table, columns }`, the referencing side |
| `to` | `{ table, columns }`, a primary or unique key on the referenced side |
| `enforced` | `true`: a foreign key the database enforces (MySQL, PostgreSQL). `false`: logical, drawn and checked by Schema Forge, never written as a constraint (always the case on Iceberg) |
| `on_delete`, `on_update` | for enforced ones: `no action`, `restrict`, `cascade`, `set null`, `set default` |
| `deferrable` | PostgreSQL |

Cardinality is not stored; it is read from the model: one-to-one when `from` columns are unique, otherwise
one-to-many; optional when any `from` column is nullable.

### View

| Field | |
|---|---|
| `id`, `namespace`, `name`, `comment`, `tags`, `area` | |
| `columns` | `[{ name, type (when known), comment }]` |
| `definition` | the `SELECT`, kept exactly as written |
| `reads` | the tables and views it reads, found by parsing the definition; kept up to date |
| `options` | the target's own, below |

| MySQL | PostgreSQL | Iceberg |
|---|---|---|
| `algorithm`, `sql_security`, `definer`, `check_option` | `materialized` (with its indexes and `with_data`), `check_option`, `security_barrier`, `security_invoker` | `versions`: each with its schema, `representations` (one `SELECT` per dialect: `spark`, `trino`, …), `default_catalog`, `default_namespace`; the current version |

For Iceberg, `definition` is the representation in the project's chosen dialect, and every other dialect's
text is kept beside it.

### Sequence (PostgreSQL)

`id`, `namespace`, `name`, `type`, `start`, `increment`, `min`, `max`, `cache`, `cycle`, `owned_by`
(a column).

### Area

`id`, `name`, `colour`. A table or view belongs to at most one area.

### Kept statements

Everything else in an imported dump: functions, procedures, triggers, grants, owners, extensions,
`SET` lines, events, policies.

| Field | |
|---|---|
| `id`, `kind` | `function`, `trigger`, `grant`, `extension`, `setting`, `other` |
| `text` | exactly as read |
| `after` | the object it followed in the dump (or `start`), so it is written back in the same place |
| `refers_to` | objects it names, where the parser can tell, so dropping a table warns about its trigger |

## Rules every schema keeps

Checked on every change; a change that breaks one is refused.

- Names are unique within their namespace (tables and views share one name space), columns within their
  table, field IDs within an Iceberg table.
- A primary key's columns are not nullable. Iceberg identifier fields are required, not float or double,
  not inside a list or map.
- A relationship points at a primary or unique key, with as many columns, of matching types.
- An enforced relationship is impossible on Iceberg.
- Every column, key, index and option exists in the project's target.
- View dependencies have no cycles; a view's `reads` exist.
- Partition and sort fields point at columns of the table, with a transform that fits the column's type.

These are the model's own rules. Project rules (naming, SCD Type 2, custom ones) come on top, from
`rules.toml` (see [rules.md](rules.md)).

## Operations

Every change is one operation, made by the agent (you direct; you do not edit). Each names who made it and the turn it belongs
to, is checked, applied, written to `operations.jsonl`, and carries what is needed to undo it.

| Area | Operations |
|---|---|
| Namespaces, areas | `add_namespace`, `rename_namespace`, `drop_namespace`; `add_area`, `set_area` |
| Tables | `add_table`, `rename_table`, `drop_table`, `set_partition_policy`, `add_partition`, `detach_partition`, `split_partition` (designed partitions), `move_table` (namespace), `set_table_comment`, `set_table_option`, `tag`, `untag` |
| Columns | `add_column` (at a position), `rename_column`, `alter_column` (type, nullable, default, generated, identity, collation, comment), `move_column`, `drop_column` |
| Keys | `set_primary_key`, `add_unique`, `drop_unique`, `add_check`, `drop_check`, `set_identifier_fields` |
| Indexes | `add_index`, `drop_index` |
| Relationships | `relate`, `alter_relationship`, `unrelate` |
| Iceberg | `set_partition_spec`, `set_sort_order`, `set_property`, `unset_property` |
| Views | `add_view`, `alter_view` (definition, columns, options; on Iceberg a new version), `rename_view`, `drop_view`, `add_view_dialect` (Iceberg) |
| Sequences, types | `add_sequence`, `alter_sequence`, `drop_sequence`; `add_type`, `alter_type`, `drop_type` |
| Patterns | `apply_pattern` (e.g. SCD Type 2 on a table: adds what is missing, as the operations above) |

**Destructive** operations (dropping a table, column, key or view; narrowing a type; making a column not
nullable) need an explicit flag, and say what they would break: the views that read it, the relationships
that use it, the kept statements that name it.

## Versions

A locked version is the schema with everything but facts removed, written in a canonical form (keys
sorted, fixed number formatting) and hashed with BLAKE3. The hash is the version's identity: the same
schema always gives the same hash, on any machine.

## Conversion

Converting to another target makes a new project and a report of every decision:

- types mapped to their nearest equal (`varchar(255)` to Iceberg `string`, `numeric(12,2)` to
  `decimal(12,2)`), and anything without an equal reported, never silently dropped;
- MySQL or PostgreSQL to Iceberg: foreign keys become logical relationships, primary keys become
  identifier fields, indexes are listed for you to turn into a sort order or partition spec;
- Iceberg to MySQL or PostgreSQL: logical relationships can become foreign keys, if you choose;
- views: the definition is translated to the new dialect where it can be, and flagged where it cannot.

## Example

Orders with SCD Type 2 on PostgreSQL (shortened):

```json
{
  "format": 1,
  "target": "postgres",
  "namespaces": [{ "id": "n_public", "name": "public" }],
  "tables": [
    {
      "id": "t_customers", "namespace": "n_public", "name": "customers", "comment": "People who order.",
      "columns": [
        { "id": "c_customers_id", "name": "id", "type": { "name": "bigint" }, "nullable": false,
          "identity": { "always": true } },
        { "id": "c_customers_email", "name": "email", "type": { "name": "text" }, "nullable": false }
      ],
      "primary_key": { "name": "customers_pkey", "columns": ["c_customers_id"] },
      "uniques": [{ "id": "u_customers_email", "name": "customers_email_key", "columns": ["c_customers_email"] }]
    },
    {
      "id": "t_orders", "namespace": "n_public", "name": "orders", "comment": "Every version of every order.",
      "tags": ["scd2"],
      "patterns": { "scd2": { "business_key": ["c_orders_order_no"] } },
      "columns": [
        { "id": "c_orders_order_key", "name": "order_key", "type": { "name": "bigint" }, "nullable": false,
          "identity": { "always": true } },
        { "id": "c_orders_order_no", "name": "order_no", "type": { "name": "text" }, "nullable": false },
        { "id": "c_orders_customer_id", "name": "customer_id", "type": { "name": "bigint" }, "nullable": false },
        { "id": "c_orders_total", "name": "total", "type": { "name": "numeric", "precision": 12, "scale": 2 }, "nullable": false },
        { "id": "c_orders_valid_from", "name": "valid_from", "type": { "name": "timestamp", "with_time_zone": true }, "nullable": false },
        { "id": "c_orders_valid_to", "name": "valid_to", "type": { "name": "timestamp", "with_time_zone": true }, "nullable": true }
      ],
      "primary_key": { "name": "orders_pkey", "columns": ["c_orders_order_key"] },
      "uniques": [{ "id": "u_orders_version", "name": "orders_version_key", "columns": ["c_orders_order_no", "c_orders_valid_from"] }],
      "indexes": [{ "id": "i_orders_customer", "name": "orders_customer_idx", "parts": [{ "column": "c_orders_customer_id" }] }]
    }
  ],
  "relationships": [
    { "id": "r_orders_customer", "name": "orders_customer_fkey", "from": { "table": "t_orders", "columns": ["c_orders_customer_id"] },
      "to": { "table": "t_customers", "columns": ["c_customers_id"] }, "enforced": true, "on_delete": "restrict" }
  ],
  "views": [
    { "id": "v_current_orders", "namespace": "n_public", "name": "current_orders", "comment": "Each order as it is now.",
      "definition": "SELECT order_no, customer_id, total FROM orders WHERE valid_to IS NULL",
      "reads": ["t_orders"] }
  ]
}
```

The same `orders` on Iceberg differs only where Iceberg differs: `bigint` becomes `long`, `numeric`
becomes `decimal`, `timestamp with time zone` becomes Iceberg `timestamptz`; columns carry `field_id`s; the relationship to
`customers` has `enforced: false`; the table has `identifier_fields: ["c_orders_order_key"]`, a `partition_spec` such as
`[{ "source": "c_orders_valid_from", "transform": "month" }]` and a `sort_order` on `order_no`; the view carries its Spark
and Trino `representations`.


## Decided

- **One target per project** (operator, 2026-11-20). Conversion makes a new project.
- **Readable ids** (operator, 2026-11-20), as in [Ids](#ids).
- **References by id** (operator, 2026-11-20).
- **Functions, procedures and triggers: verbatim now, objects later** (operator, 2026-11-20): version 1
  carries them through exactly, in place, knowing which tables they name; a later version makes them
  objects the agent can write and edit.
- **PostgreSQL partitions: a policy, plus designed partitions** (operator, 2026-11-20). Daily partitions
  would mean hundreds of tables a year, made at runtime rather than designed, so:
  - the partitioned table holds its **partitioning policy**: key, strategy, interval, retention, and who
    creates the partitions;
  - only **designed partitions** are tables (`partition_of` and bounds): a few named ones such as list
    partitions, `DEFAULT`, an archive;
  - an imported **series** (daily, monthly) is recognised, shown as one badge ("1,096 daily partitions,
    2023-01-01 → 2025-12-31"), and its statements kept verbatim, so nothing is lost.
