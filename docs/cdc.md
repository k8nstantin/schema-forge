# CDC: MySQL to Iceberg through Debezium

You capture changes from a MySQL database with Debezium and land them in Iceberg tables. The hard part
is not the pipeline; it is knowing, column by column, what each MySQL type becomes on the way, and finding
the inconsistencies in the source before they turn into broken or silently wrong data.

Schema Forge designs the Iceberg side from the MySQL side, under rules, and shows every inconsistency
first.

## The idea

```
 MySQL schema ──► consistency check ──► pipeline (rules, Debezium's included) ──► Iceberg schema
  (imported)      every problem shown      every column mapped, decided once       + mapping report
                                                                                     + Debezium settings
```

- The source follows the **Debezium rule pack** ([rules.md](rules.md#debezium-a-rule-pack)), which a
  pipeline adds to it.
- A **pipeline** links two schemas in Schema Forge: a MySQL source and an Iceberg target. It carries the
  rules for the mapping, including the Debezium rule pack's connector settings.
- The Iceberg tables are generated from the source by those rules; you and the agent then refine them
  (partitions, sort orders, extra columns) like any schema.
- When the source changes, the pipeline shows what the Iceberg side must do: an allowed schema evolution,
  or a change it cannot take, flagged.

## Inconsistencies, shown first

Before anything is mapped, the source is checked. Every finding is marked on the tables and columns in
every perspective, gathered in the **Consistency** perspective, and given to the agent with a suggested fix.

**Inconsistencies in the source:**

- the same column, different types: `customer_id int` in one table, `bigint` in another
- a relationship whose two ends differ: `int` referencing `bigint`, signed referencing unsigned
- one kind of data in many types: money as `decimal(10,2)`, `decimal(12,2)` and `double`
- lengths that drift: `email varchar(100)` here, `varchar(255)` there
- mixed character sets or collations across tables
- `DATETIME` and `TIMESTAMP` both used for points in time (Debezium treats them differently, below)
- `TINYINT(1)` used as a boolean in some tables and as a number in others

**Hazards on the way to Iceberg through Debezium:**

- `BIGINT UNSIGNED`: Debezium's default (`bigint.unsigned.handling.mode=long`) silently corrupts values
  above 2^63 − 1; the safe choice is `precise`, giving `decimal(20,0)`
- a table without a primary key: no identifier fields on the Iceberg side, so no upserts, only appends
- zero dates (`0000-00-00`): become `null` for nullable columns and the epoch for `NOT NULL` ones
- `TIME` values outside a day (MySQL allows up to 838 hours): only 00:00 to 23:59:59.999999 is captured
  correctly
- `ENUM` and `SET` arrive as strings; their allowed values are lost unless kept (as a comment or a check)
- `FLOAT` or `DOUBLE` for money
- `DECIMAL` under `decimal.handling.mode=double` or `string`: precision lost or the type changed

## How each MySQL type lands

With the Debezium rule pack's shipped defaults (below):

| MySQL | Debezium event | Iceberg |
|---|---|---|
| `TINYINT`, `SMALLINT`, `MEDIUMINT`, `INT` | integer | `int` |
| `INT UNSIGNED` | integer | `long` |
| `BIGINT` | `INT64` | `long` |
| `BIGINT UNSIGNED` | `Decimal` (`precise`) | `decimal(20,0)` |
| `TINYINT(1)` used as a boolean | `BOOLEAN` (with the TinyInt-to-boolean converter) | `boolean` |
| `BIT(1)` | `BOOLEAN` | `boolean` |
| `DECIMAL(p,s)` | `Decimal` (`precise`) | `decimal(p,s)` |
| `FLOAT`, `DOUBLE` | `FLOAT32`, `FLOAT64` | `float`, `double` (flagged when the kind is money) |
| `CHAR`, `VARCHAR`, `TEXT` | `STRING` | `string` |
| `ENUM`, `SET` | `STRING` (`Enum`, `EnumSet`) | `string`, allowed values kept in the comment |
| `JSON` | `STRING` (`Json`) | `string`, or `variant` on format version 3 |
| `DATE` | `Date` (days since epoch) | `date` |
| `DATETIME(fsp)` | `Timestamp` / `MicroTimestamp`, no time zone | `timestamp` (no zone) |
| `TIMESTAMP(fsp)` | `ZonedTimestamp`, ISO 8601 in UTC | `timestamptz` |
| `TIME` | `MicroTime` | `time` |
| `YEAR` | `INT32` (`Year`) | `int` |
| `BINARY`, `VARBINARY`, `BLOB` | `BYTES` (`binary.handling.mode=bytes`) | `binary` |
| `GEOMETRY` and subtypes | `STRUCT` (`srid`, `wkb`) | `geometry` on format version 3, else a struct |

Every row is a rule: you can change any of them in the pipeline's rules, and the change shows at once on
every table it affects.

## Debezium's settings are rules

How types travel (`decimal.handling.mode`, `bigint.unsigned.handling.mode`, `time.precision.mode`,
`binary.handling.mode`, the TinyInt-to-boolean converter, the zero-date fallback) is set in the **Debezium
rule pack** ([rules.md](rules.md#debezium-a-rule-pack)), in Standards, per template or per schema, like any
other rule. The pipeline reads them, maps every column by them, and writes them out for the connector, so
the two can never disagree. The type table above assumes the shipped defaults.

## The Iceberg tables

Generated by the pipeline's rules, then refined with the agent:

- **identifier fields** from the MySQL primary key, so changes are upserts; a table without one is flagged
  (append-only, or you choose a key)
- **merge-on-read** for deletes, updates and merges, and format version 3, from the Iceberg defaults
- **partition spec and sort order** from the rules (e.g. by `day` of a time column, sorted by the key)
- **CDC columns**, if the rules ask for them, named by the naming rules: the operation (`c`, `u`, `d`,
  `r`), the event time, and the source position (binlog file and position, or GTID)
- **deletes**: applied as deletes, or kept as rows marked deleted, as the rules say
- **relationships** carried over as logical ones, so the diagram stays the same shape

## What comes out

- the Iceberg schema, a normal Schema Forge schema
- the **mapping report**: every source column, its Iceberg column, the rule that decided it, and every
  inconsistency and hazard with what was done about it
- the **Debezium settings** for the connector (from the rule pack, plus the converter's column list)
- the Iceberg DDL (Spark SQL, Trino) or table metadata, as for any Iceberg schema

## When the source changes

A new locked version of the MySQL schema is compared with what the pipeline last mapped:

- additions (a new table, a new nullable column) map by the rules, as before
- widenings Iceberg allows (`int` to `long`, `float` to `double`, a larger decimal precision) become
  schema evolution on the Iceberg table
- anything else (a narrower type, a changed key, a dropped column the target still holds) is flagged with
  what it would break, for you to decide
