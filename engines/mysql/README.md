# The MySQL engine

Everything Schema Forge knows about MySQL, in one crate: its versions, its types, every kind of object it has and
every clause of their definitions, reading a schema from a dump or from the live database, writing its SQL, and its
types as Apache Arrow's. Nothing outside this crate knows MySQL; nothing in it is shared with another engine. When
something about MySQL is wrong, it is wrong here.

This is the plan, agreed before the code; it becomes the crate's own documentation as it is built. It is the first
engine, so it is also the proof of the plugin design: built exactly as an engine written outside Schema Forge would be,
on the model and the engine interface alone. Whatever it needs that the interface lacks is a finding about the
interface, fixed there in its own step.

## Versions

Checked against MySQL's own release notes. What grows is the table in `versions.rs`; nothing tests a version number.

| Version | What it is | What changed that the model holds |
|---|---|---|
| 8.0 | end of life since 30 April 2026 (8.0.46 the last); still what many databases run | the base: enforced checks, functional and descending index parts, invisible columns and indexes, expression defaults, generated invisible primary keys, read-only databases |
| 8.4 | long-term support | `AUTO_INCREMENT` on `FLOAT`/`DOUBLE` removed; a foreign key to a non-unique or partial key refused by default; a column prefix in a partitioning key removed; unquoted names with more than one `$` refused; new reserved words (`QUALIFY`, `PARALLEL`, `MANUAL`, `TABLESAMPLE` and others); versioned comments of five or six digits |
| 9.7 | long-term support (April 2026) | `VECTOR(N)` (from 9.0; never part of any key or partitioning); inline `REFERENCES` enforced and the parent's primary key implied (from 9.0); JavaScript stored programs (9.0, Enterprise); libraries (`CREATE LIBRARY`, from 9.2; WASM by 9.7) |
| 26.7, 26.10 | innovation releases, calendar-versioned after 9.7 | read from their release notes and real dumps as the engine is built, before they are offered |

A new schema starts at **8.4**. Deprecated forms (an integer display width like `int(11)`, `ZEROFILL`, `FLOAT(M,D)`,
`UNSIGNED` on `FLOAT`, `DOUBLE` and `DECIMAL`, the `utf8mb3` charset) are read and kept, and the checks flag them.

## Every kind of object

| Kind | Slots | What it holds |
|---|---|---|
| `table` | keys, checks, indexes, partitioning | columns, keys, checks, indexes, foreign keys (as links), partitioning, table options |
| `view` | query | its query, columns, algorithm, definer, SQL security, check option |
| `procedure` | routine | parameters (in, out, inout), characteristics, body |
| `function` | routine | parameters, what it returns, characteristics, body |
| `loadable_function` | routine | a function from a library file (`CREATE [AGGREGATE] FUNCTION … RETURNS … SONAME`) |
| `library` | routine | a JavaScript or WASM library a routine imports (from 9.2), its source as written |
| `trigger` | trigger | timing, the change, its table, its order, body |
| `event` | event | schedule, on completion, status, body |
| `tablespace` | | a general tablespace: data file, block size, encryption, engine, autoextend size |
| `spatial_reference_system` | | an SRS: id, name, definition, organization, description |

A namespace is a MySQL database, one level deep: its default charset, collation, encryption and read-only state are
its options. Partitions are defined inside their table, so they live in its partitioning, never as objects.

| Kept as written, counted by kind | Why |
|---|---|
| users, roles and grants | the server's accounts and rights, not a schema's design |
| resource groups | the server's thread scheduling |
| servers (for `FEDERATED` tables) | the server's connections to other servers |
| table data (`INSERT`, `LOCK TABLES`) | data, left out and counted |

## Every clause, and where it goes

Nothing in a definition is dropped: each clause is modelled in a slot of the layout, declared as an option, or, for a
whole statement the model cannot describe, kept exactly as written and counted.

**A column:** type; `NULL`/`NOT NULL`; `DEFAULT` (a literal or an expression); `AUTO_INCREMENT` (identity, numbered
by default; the table's start in its options); generated `VIRTUAL`/`STORED`; options: `VISIBLE`/`INVISIBLE`,
`CHARACTER SET`, `COLLATE`, `ON UPDATE`, `SRID`, `COLUMN_FORMAT`, `STORAGE`, `ENGINE_ATTRIBUTE`,
`SECONDARY_ENGINE_ATTRIBUTE`; its `COMMENT` (the model's comment); an inline `REFERENCES` (a link, enforced from 9.0)
and an inline `CHECK` (the table's checks).

**A table:** `PRIMARY KEY`, `UNIQUE`; `CHECK` with `NOT ENFORCED` an option; indexes (`KEY`/`INDEX`, `FULLTEXT`,
`SPATIAL`) with their method (`BTREE`, `HASH`), parts (columns with a prefix length, or expressions), order, and
options (`KEY_BLOCK_SIZE`, `WITH PARSER`, `COMMENT`, `VISIBLE`/`INVISIBLE`, `ENGINE_ATTRIBUTE`); foreign keys as links
(`ON DELETE`, `ON UPDATE`, a parent in another database); partitioning (`RANGE`/`LIST` with or without `COLUMNS`,
`HASH`/`KEY`, `LINEAR`, `ALGORITHM`, `PARTITIONS n`, subpartitions, and each partition's values and options); table
options: `ENGINE`, `AUTO_INCREMENT`, `AUTOEXTEND_SIZE`, `AVG_ROW_LENGTH`, `CHARSET`, `COLLATE`, `CHECKSUM`,
`COMPRESSION`, `CONNECTION`, `DATA DIRECTORY`, `INDEX DIRECTORY`, `DELAY_KEY_WRITE`, `ENCRYPTION`,
`ENGINE_ATTRIBUTE`, `SECONDARY_ENGINE`, `SECONDARY_ENGINE_ATTRIBUTE`, `INSERT_METHOD`, `KEY_BLOCK_SIZE`, `MAX_ROWS`,
`MIN_ROWS`, `PACK_KEYS`, `ROW_FORMAT`, `STATS_AUTO_RECALC`, `STATS_PERSISTENT`, `STATS_SAMPLE_PAGES`, `TABLESPACE`,
`UNION`; its `COMMENT`.

**A view:** `ALGORITHM`, `DEFINER`, `SQL SECURITY`, its column list, its query, `WITH CASCADED|LOCAL CHECK OPTION`.

**A procedure, function or library:** `DEFINER`; parameters and `RETURNS` (with a charset); `LANGUAGE` (SQL,
JavaScript, WASM); `[NOT] DETERMINISTIC`; `CONTAINS SQL`/`NO SQL`/`READS SQL DATA`/`MODIFIES SQL DATA`; `SQL
SECURITY`; `COMMENT`; imported libraries; the body exactly as written. And what MySQL stores with each stored program
and a dump sets before it: its `sql_mode`, `character_set_client`, `collation_connection` and the database collation,
so it is written back with the same meaning.

**A trigger:** `DEFINER`, `BEFORE`/`AFTER`, `INSERT`/`UPDATE`/`DELETE`, its table, `FOLLOWS`/`PRECEDES`, the body,
and its stored `sql_mode` and character sets.

**An event:** `DEFINER`, `AT …` or `EVERY … STARTS … ENDS`, `ON COMPLETION [NOT] PRESERVE`, `ENABLE`/`DISABLE`/
`DISABLE ON REPLICA`, `COMMENT`, the body, and its stored `sql_mode`, time zone and character sets.

Every option is declared, with its part, kinds, kind of value, meaning and versions.

## Types

In palette groups, each with a plain meaning and a real example; a column holds its type as MySQL writes it in
lowercase (`int unsigned`, `varchar(200)`, `decimal(18,2)`, `enum('new','paid')`).

| Group | Types |
|---|---|
| Whole numbers | `tinyint`, `smallint`, `mediumint`, `int`, `bigint`, each `unsigned` or not |
| Exact decimals | `decimal(P,S)` (up to 65 digits) |
| Approximate numbers | `float`, `double` |
| Text | `char(N)`, `varchar(N)`, `tinytext`, `text`, `mediumtext`, `longtext` |
| Bytes | `binary(N)`, `varbinary(N)`, `tinyblob`, `blob`, `mediumblob`, `longblob` |
| Yes or no | `boolean` (MySQL's `tinyint(1)`) |
| Dates and times | `date`, `time(P)`, `datetime(P)`, `timestamp(P)`, `year` |
| Lists of values | `enum(…)`, `set(…)` |
| JSON | `json` |
| Bit strings | `bit(N)` |
| Spatial | `geometry`, `point`, `linestring`, `polygon`, `multipoint`, `multilinestring`, `multipolygon`, `geometrycollection` |
| Vectors | `vector(N)`, from 9.7 |

## Reading a dump

`mysqldump` output, with or without data, with routines, triggers and events, from 8.0 on, and hand-written DDL,
tokenised with `sqlparser`'s MySQL dialect and cut into statements by this crate's own reader, which knows what a
dump does:

- `DELIMITER` changes around routines, triggers and events, so a body's own semicolons do not end it;
- versioned comments (`/*!40101 SET … */`, `/*!50100 PARTITION BY … */`, `/*!50003 CREATE … */`), which hold real
  DDL and are read as what they contain;
- the temporary tables a dump writes for views before the views themselves, which are not tables of the schema;
- the `SET` lines before each stored program, which carry its `sql_mode` and character sets;
- `DROP … IF EXISTS`, `LOCK TABLES`, the header and the trailer, as settings.

Every statement is modelled, kept by kind, counted as data, or kept whole as not understood; the counts add up.

## Reading the live database

Over a connection ([docs/connections.md](../../docs/connections.md)), read-only:

- **connection fields**, declared as data: host, port (3306), user, the secret, database (one or several), TLS mode
  (required and verified by default; required; preferred; off), CA certificate, connect timeout;
- **test**, in five steps: reach the host; TLS as asked; sign in; the server's version (and so the engine version the
  schema is read at); rights: the user can read the definitions (`SHOW CREATE` on every kind) and whether it can also
  change anything, recommending a read-only user when it can;
- **read**: the objects are listed from `information_schema` (tables, views, routines, libraries, triggers, events,
  tablespaces, spatial reference systems), and each definition is read with `SHOW CREATE …` and parsed by the same
  reader the dumps go through, so a schema read live and one read from a dump of the same database are the same model;
  only statements that read are sent;
- **the driver**: the `mysql` crate, pure Rust, with TLS through `rustls` (no C libraries), chosen and checked when the
  engine is built.

## Writing

One object's definition, and the whole schema, in the form `SHOW CREATE …` uses, with stored programs inside
`DELIMITER` blocks with their settings, and what was kept back in its place. A schema this engine writes reads back as
the same text, and loads into a real MySQL.

## Arrow

Whole numbers to Arrow's signed or unsigned integers exactly; `decimal(P,S)` to `Decimal128` (up to 38 digits) or
`Decimal256`, exactly; `float`, `double` to `Float32`, `Float64`; text to `Utf8` (a length is not kept); bytes to
`Binary`; `date`, `time`, `datetime`, `timestamp` to Arrow's dates, times and timestamps (`timestamp` in UTC); `json`
to `Utf8` (Arrow has no JSON type); `enum` and `set` to `Utf8` (their values are not kept); spatial types to `Binary`
holding the shape as WKB; `vector(N)` to a fixed-size list of `N` 32-bit floats, exactly.

## Queries

What a view reads, from its query, with `sqlparser`'s MySQL dialect: tables and views by name, as written.

## Checks

A name longer than 64 characters; a reserved word of its version unquoted; more than one `AUTO_INCREMENT` column, or
one that is not a key; from 8.4, `AUTO_INCREMENT` on `FLOAT`/`DOUBLE`, a foreign key to columns that are not a key or
a unique, or a column prefix in a partitioning key; a `VECTOR` in any key or partitioning; a `TEXT` or `BLOB` column in
a key without a prefix length; a trigger whose table is not in the schema; the deprecated forms, flagged.

## Add-ons

The engine's own `AddOn` trait, so a company's conventions or a MySQL-compatible system's extra types and statements
are added without forking it.

## Samples and tests

In `tests/samples/`, made by this crate, never copied from a company's database:

- `shop/source.sql`: a made-up shop using every kind of object and every clause above; `source97.sql` adds what came
  after 8.4; `make.sh` loads it into a throwaway MySQL in Docker for each version (8.0, 8.4, 9.7, 26.10) and dumps it
  with that server's own `mysqldump`, schema-only and whole, with routines, triggers and events;
- `shop.sql`: the shop as this engine writes it (written back as the same text), checked by loading it into MySQL.

The tests: the conformance kit on every sample; every statement of every dump accounted for; one test for each kind of
object and each clause, read and written; each version's features offered and refused where they should be; and,
against MySQL in Docker, the live test's five steps and the live read giving the same schema as the dump.

## Done when

The kit passes on every sample; every dump's statements add up; every kind of object and every clause above reads and
writes; the live read of each version equals its dump's read; the canonical sample comes back as the same text and
loads into MySQL; and the architecture check finds MySQL named nowhere but here.
