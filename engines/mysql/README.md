# The MySQL engine

Everything Schema Forge knows about MySQL, in one crate: its versions, its types, every kind of object it has and
every clause of their definitions, reading a schema from a dump, from hand-written DDL or from the live database,
writing its SQL, its checks, and its types as Apache Arrow's. Nothing outside this crate knows MySQL; nothing in it is
shared with another engine. When something about MySQL is wrong, it is wrong here.

It is the first engine, and so the proof of the plugin design: it is built exactly as an engine written outside
Schema Forge would be, on the model and the engine interface alone. The one thing it needed from the interface,
reading a live database (`Live`), was added with it. It was planned whole before it was built; this page is that plan,
as built.

| Part | Where |
|---|---|
| versions, and what each changed | `src/versions.rs` |
| types, one table | `src/types.rs` |
| kinds of object, options | `src/kinds.rs`, `src/options.rs` |
| a script cut into statements | `src/dump.rs`, `src/lex.rs` |
| reading | `src/read/` (tables; views and stored programs; databases, tablespaces, spatial reference systems, accounts) |
| writing | `src/write.rs` |
| the live database | `src/live.rs` |
| checks, queries, Arrow | `src/checks.rs`, `src/queries.rs`, `src/portable.rs` |
| add-ons | `src/addon.rs` |

## Versions

Checked against MySQL's own release notes. What grows is the table in `versions.rs`; nothing tests a version number.

| Version | What it is | What changed that the model holds |
|---|---|---|
| 8.0 | end of life since 30 April 2026 (8.0.46 the last); still what many databases run | the base: enforced checks, functional and descending index parts, invisible columns and indexes, expression defaults, read-only databases |
| 8.4 | long-term support | `AUTO_INCREMENT` on `FLOAT`/`DOUBLE` removed; a foreign key to columns that are not a primary key or a unique refused by default; a column prefix in a partitioning key removed |
| 9.7 | long-term support (April 2026) | `VECTOR(N)` (from 9.0; never part of a key, an index or the partitioning); a foreign key written on its column (`REFERENCES`) enforced (from 9.0); JavaScript stored programs (9.0) and libraries (`CREATE LIBRARY`, 9.2) |
| 26.7, 26.10 | innovation releases, numbered by year and month after 9.7 | read from real dumps of 26.10: nothing new that a schema holds |

A new schema starts at **8.4**. A server's version falls in the first of these not older than it (9.1 is read as
9.7, 27.1 as 26.10). Deprecated forms (an integer display width like `int(11)`, `ZEROFILL`, `FLOAT(M,D)`, `UNSIGNED`
on `FLOAT`, `DOUBLE` and `DECIMAL`) are read, kept and written as they are; advice about them belongs to the rules.

## Every kind of object

| Kind | Slots | What it holds |
|---|---|---|
| `table` | keys, checks, indexes, partitioning | columns, keys, checks, indexes, foreign keys (as links), partitioning, table options |
| `view` | query | its query, algorithm, definer, SQL security, column list, check option |
| `procedure` | routine | parameters (in, out, inout), characteristics, body |
| `function` | routine | parameters, what it returns, characteristics, body |
| `loadable_function` | | a function from a library file (`CREATE [AGGREGATE] FUNCTION … RETURNS … SONAME`): what it returns and its file, as options |
| `library` | routine | a JavaScript or WASM library a routine imports (from 9.2), its source as written |
| `trigger` | trigger | timing, the change, its table, its order, body |
| `event` | event | schedule, on completion, status, body |
| `tablespace` | | a general tablespace: data file, block size, encryption, engine, autoextend size |
| `spatial_reference_system` | | an SRS: id, name, definition, organization, description |

A namespace is a MySQL database, one level deep: its default charset, collation, encryption and read-only state are
its options. A file that names no database puts its objects in one called `default`. Partitions are defined inside
their table, so they live in its partitioning, never as objects. Tablespaces, spatial reference systems and loadable
functions belong to the server; they are kept in the database they were read with.

| Kept as written, counted by kind | Why |
|---|---|
| accounts (`CREATE USER`, `ALTER USER`, roles) | the server's accounts, not a schema's design; **never with a credential**: every `IDENTIFIED …` clause is cut out and the account kept locked (`ACCOUNT LOCK`), so what is written back never makes an account that signs in without a password; `SET PASSWORD` is left out, counted with the data |
| grants (`GRANT`, `REVOKE`) | the server's rights; an old grant's `IDENTIFIED BY` cut out |
| resource groups | the server's thread scheduling |
| servers (for `FEDERATED` tables) | the server's connections to other servers; a server's `PASSWORD` cut out |
| what the reader does not know (an `ALTER TABLE`, a table made `LIKE` another) | kept whole as `other`, written back in its place, and listed in the report |

## Every clause, and where it goes

Nothing in a definition is dropped: each clause is modelled in a slot of the layout, declared as an option, or, for a
whole statement the model cannot describe, kept exactly as written and counted.

**A column:** type; `NULL`/`NOT NULL`; `DEFAULT` (a literal, a function or an expression, as written);
`AUTO_INCREMENT` (an identity; the table's next number is its option); generated `VIRTUAL`/`STORED`; options:
`INVISIBLE`, `CHARACTER SET`, `COLLATE`, `ON UPDATE`, `SRID`, `COLUMN_FORMAT`, `STORAGE`, `ENGINE_ATTRIBUTE`,
`SECONDARY_ENGINE_ATTRIBUTE`; its `COMMENT` (the model's comment); a `PRIMARY KEY` or `UNIQUE` on it (the table's
keys); a `REFERENCES` on it (a link, marked `inline`: enforced from 9.0, before it a link MySQL does not enforce); a
`CHECK` on it (the table's checks).

**A table:** `PRIMARY KEY` and `UNIQUE` (a key of whole columns; a column prefix or a descending part is in the key's
`parts`; a unique with an expression is a unique index); `CHECK`, with `NOT ENFORCED` an option; indexes (`KEY`/`INDEX`,
`FULLTEXT`, `SPATIAL`, `CREATE INDEX`) with their method (`btree`, `hash`, `fulltext`, `spatial`), parts (columns
with a prefix length, or expressions), order, and options (`KEY_BLOCK_SIZE`, `WITH PARSER`, `COMMENT`, `INVISIBLE`,
`ENGINE_ATTRIBUTE`), an index without a name named as MySQL names it; foreign keys as links (`MATCH`, `ON DELETE`,
`ON UPDATE`, a parent in another database of the schema), and one to a table outside the schema kept as written on its
table (`outside_references`); partitioning (`RANGE`/`LIST` with or without `COLUMNS`, `HASH`/`KEY`, `LINEAR`,
`ALGORITHM`, `PARTITIONS n`, subpartitions, and each partition's bounds and options); table options: `ENGINE`,
`AUTO_INCREMENT`, `AUTOEXTEND_SIZE`, `AVG_ROW_LENGTH`, `CHARSET`, `COLLATE`, `CHECKSUM`, `COMPRESSION`, `CONNECTION`,
`DATA DIRECTORY`, `INDEX DIRECTORY`, `DELAY_KEY_WRITE`, `ENCRYPTION`, `ENGINE_ATTRIBUTE`, `SECONDARY_ENGINE`,
`SECONDARY_ENGINE_ATTRIBUTE`, `INSERT_METHOD`, `KEY_BLOCK_SIZE`, `MAX_ROWS`, `MIN_ROWS`, `PACK_KEYS`, `ROW_FORMAT`,
`STATS_AUTO_RECALC`, `STATS_PERSISTENT`, `STATS_SAMPLE_PAGES`, `TABLESPACE`, `UNION`; its `COMMENT`.

**A view:** `ALGORITHM`, `DEFINER`, `SQL SECURITY`, its column list, its query, `WITH CASCADED|LOCAL CHECK OPTION`;
what it reads, worked out from its query.

**A procedure, function or library:** `DEFINER`; parameters and `RETURNS`, each type as written (with its charset);
`LANGUAGE` (SQL, JavaScript); `[NOT] DETERMINISTIC`; `CONTAINS SQL`/`NO SQL`/`READS SQL DATA`/`MODIFIES SQL DATA`;
`SQL SECURITY`; `COMMENT`; imported libraries (`USING`); the body exactly as written, dollar-quoted JavaScript
included. And what MySQL stores with each stored program, which a dump sets before it: its `sql_mode`,
`character_set_client` and `collation_connection`, so it is written back with the same meaning.

**A trigger:** `DEFINER`, `BEFORE`/`AFTER`, `INSERT`/`UPDATE`/`DELETE`, its table, `FOLLOWS`/`PRECEDES`, the body,
and its stored settings; triggers on one table keep their order.

**An event:** `DEFINER`, `AT …` or `EVERY … STARTS … ENDS`, `ON COMPLETION [NOT] PRESERVE`, `ENABLE`/`DISABLE`/
`DISABLE ON REPLICA`, `COMMENT`, the body, and its stored settings and time zone.

Every option is declared, with its part, kinds, kind of value and meaning. Options are stored in the order of their
keys, so a schema is the same file however its SQL ordered the clauses.

## Types

In palette groups, each with a plain meaning and a real example; a column holds its type as MySQL writes it in
lowercase (`int unsigned`, `varchar(200)`, `decimal(18,2)`, `enum('new','paid')`), every spelling MySQL accepts read
as that (`integer` is `int`, `numeric` is `decimal(10,0)`, `boolean` is `tinyint(1)`, `year(4)` is `year`, `serial`
is `bigint unsigned NOT NULL AUTO_INCREMENT UNIQUE`). `text(N)` and `blob(N)` keep their size: MySQL makes each the
smallest type that holds N characters of the column's character set, or N bytes, which only the server knows. The
`BINARY` attribute of a text column is its option `binary`; `ASCII` and `UNICODE` are its character set. An `enum` or
`set` value keeps every character, written as MySQL writes it (`'a\\b'`, `'c\nd'`, `'it''s'`).

| Group | Types |
|---|---|
| Whole numbers | `tinyint`, `smallint`, `mediumint`, `int`, `bigint`, each `unsigned` or not |
| Exact decimals | `decimal(P,S)` (up to 65 digits) |
| Approximate numbers | `float`, `double` |
| Text | `char(N)`, `varchar(N)`, `tinytext`, `text`, `mediumtext`, `longtext` |
| Bytes | `binary(N)`, `varbinary(N)`, `tinyblob`, `blob`, `mediumblob`, `longblob` |
| Yes or no | `tinyint(1)`, MySQL's boolean |
| Dates and times | `date`, `time(P)`, `datetime(P)`, `timestamp(P)`, `year` |
| Lists of values | `enum(…)`, `set(…)` |
| JSON | `json` |
| Bit strings | `bit(N)` |
| Spatial | `geometry`, `point`, `linestring`, `polygon`, `multipoint`, `multilinestring`, `multipolygon`, `geomcollection` |
| Vectors | `vector(N)`, from 9.7 |

## Reading a dump or DDL

`mysqldump` output (schema only or whole, with routines, triggers and events, from 8.0 on), what this engine writes,
and hand-written DDL. The script is cut into statements as the `mysql` client cuts it (`src/dump.rs`), each statement
tokenised with `sqlparser`'s MySQL dialect, and expressions and bodies taken from the text exactly as written:

- versioned comments (`/*!50003 … */`) are read as the code they hold, every byte kept in its place;
- `DELIMITER` changes what ends a statement; quotes, comments and dollar-quoted bodies never end one;
- the placeholder a dump writes for a view before the views themselves is dropped with the dump's own `DROP VIEW`,
  counted as the dump's machinery, and the view keeps one id; so does a view made again (`CREATE OR REPLACE`);
- the `SET` lines before each stored program carry its settings into it; one restoring a saved value forgets them;
- `DROP … IF EXISTS`, `LOCK TABLES`, the header and the trailer are the dump's machinery; rows are data; both are
  counted and left out;
- a foreign key may name a table the dump writes later: links are made once every table is read; a trigger is made
  on a table already read, as MySQL makes one, and a trigger whose table is not in the schema is kept in its place;
- rows are counted by their first word and never tokenised, statements borrow the file, and lines are counted once,
  so a whole dump is read in one pass and held once.

What is not MySQL's is refused, not misread: a MariaDB dump (its header, its `/*M!…*/` comments, or its server
version), and statements made under the SQL mode `NO_BACKSLASH_ESCAPES`, whose strings a reader that takes a
backslash as an escape would misread.

The version a file is read at: the one this engine's header names (`-- MySQL 8.4 schema, written by Schema Forge`),
the one a dump's `-- Server version` line falls in, or 8.4. A person names it in hand-written DDL with a line like
`-- Server version 9.7`. A whole dump's rows need not be UTF-8: they are data, and every byte that ends a statement or
a quote is ASCII.

Every statement is modelled, kept as written by kind, counted as data, or counted as the dump's machinery; the report
adds up.

## Reading the live database

Over a connection ([docs/connections.md](../../docs/connections.md)), with the `mysql` crate (pure Rust, TLS through
`rustls`), sending only statements that read:

- **connection fields**, declared as data: host, port (3306), user, the password (a secret, never in a profile),
  databases (all the account sees when empty), TLS (`verify`, the default: encrypted and the certificate checked;
  `required`; `preferred`; `off`), a CA certificate, a timeout;
- **test**, in five steps, stopping at the first that fails: **reach** the host; **secure**: TLS as asked, and what
  was negotiated; **sign in**; **version**: the server's, and the engine version a schema read from it is designed
  for (a MariaDB server fails here: it is not MySQL); **rights**: the account's grants read with where each applies
  (everywhere, a database or a pattern of databases, or only some tables) and with its active roles' grants, naming
  every right it lacks, and whether it can also change anything (an account that only reads is recommended);
- **read**: each database's definitions as the server writes them (`SHOW CREATE …`), in `mysqldump`'s order (tables
  with their triggers, events, libraries, functions, procedures, views), from inside the database as `mysqldump` is,
  read through the same reader as a dump: a schema read live and one read from a dump of the same database are the
  same model. The server's general tablespaces and the spatial reference systems people defined (MySQL's own come from
  the EPSG) are read too, which a dump leaves out.

The rights reading needs, and MySQL has no narrower ones: `SELECT, SHOW VIEW, TRIGGER, EVENT` on each database read,
and `SHOW_ROUTINE` and `PROCESS` everywhere (`TRIGGER` and `EVENT` to see triggers and events, `SHOW_ROUTINE` a
routine's body, `PROCESS` the general tablespaces). Without `TRIGGER` or `EVENT`, MySQL hides those objects rather
than refusing, so a read by an account that lacks any of these is refused, never returned with something missing.

Not yet proven against a server: reading libraries (`SHOW CREATE LIBRARY`, `information_schema.LIBRARIES`), which
need MySQL Enterprise; libraries are read and written from files, and tested that way.

## Writing

One object's definition, and the whole schema, in one canonical form: each object as `SHOW CREATE …` writes it,
without the versioned comments, every name quoted; stored programs inside `DELIMITER` with the settings they were made
under, saved before and restored after; foreign key checks off while the schema is made, so tables come in any order;
a view after what it reads, in any database (with `USE` where it must switch); what the reader kept, written back
after the part it followed. Every string is written as `SHOW CREATE …` writes one; every setting is a quoted string;
every value written outside quotes (an engine, a character set, a collation, a size, a definer) must be one word or an
account, so no value can change the statement around it. A link marked as written on its column is written there
when that keeps its meaning in the schema's version, and as a constraint when MySQL would ignore it on the column.
Writing returns an error rather than drop or change anything: a link MySQL does not enforce on several columns, or
from 9.0 at all; an identity numbered other than by `AUTO_INCREMENT`; an index with a `WHERE`; a value that is not
one word.

What this engine writes reads back as the same schema, and loads into MySQL: each canonical sample is loaded into a
server of its version and dumped again by that server's own `mysqldump`, and that dump reads as the same schema as the
dump of the original.

## Arrow

Whole numbers to Arrow's signed or unsigned integers exactly (`mediumint` to 32 bits, approximately; a display width
or `ZEROFILL` is not kept); `tinyint(1)` to `Boolean`; `decimal(P,S)` to `Decimal128` (up to 38 digits) or
`Decimal256`, exactly; `float`, `double` to `Float32`, `Float64`; text to `Utf8` (a length is not kept); `binary(N)`
to `FixedSizeBinary(N)` exactly, other bytes to `Binary`; `date` to `Date32`; `datetime(P)` and `timestamp(P)` to
timestamps (`timestamp` in UTC), exactly at 0, 3 and 6 digits; `time` to `Time64`, approximately (a MySQL time is a
duration up to 838 hours); `year` to `Int16`; `json`, `enum` and `set` to `Utf8` (Arrow has no JSON type; the values
are not kept); bit strings and spatial types to `Binary` (shapes as well-known binary); `vector(N)` to a fixed-size
list of `N` 32-bit floats, exactly. And back: every Arrow type to the nearest MySQL type, saying what is lost.

## Queries

What a view reads, from its query, with `sqlparser`'s MySQL dialect: tables and views by name, as written; the names a
query gives its own common table expressions are not tables.

## Checks

What MySQL refuses: a name longer than 64 characters; more than one `AUTO_INCREMENT` column, or one that is not the
first column of a key; from 8.4, `AUTO_INCREMENT` on `FLOAT`/`DOUBLE`, a foreign key to columns that are not a
primary key or a unique, whole, and a `KEY`-partitioned table by a column with a prefix in its key; a `VECTOR` in any
key, index or partitioning; a `TEXT` or `BLOB` in a key or a non-full-text index without a prefix length; a trigger on
a view; a link MySQL cannot hold. Names are always written quoted, so a reserved word is never a problem.

## Add-ons

`AddOn` (`src/addon.rs`): a company's conventions or a MySQL-compatible system's types are added without forking the
engine, with one line, `Mysql::new().with(MyAddOn)`. An add-on's types join the catalog after MySQL's own and read and
write like them (`tests/addon.rs` is the worked example). Statement handlers and rules open to add-ons as the engine
grows them.

## Samples and tests

In `tests/samples/`, made by this crate, never copied from a company's database:

- `shop/source.sql`: a made-up shop using every kind of object and clause the free server can make; `source97.sql`
  adds what came after 8.4; `make.sh` loads it into a throwaway MySQL in Docker for each version (8.0, 8.4, 9.7,
  26.10) and dumps it with that server's own `mysqldump`, schema only (`schema<v>.sql`) and whole (`full<v>.sql`);
- `shop/shop<v>.sql`: the shop as this engine writes it for each version; `roundtrip.sh` loads each into a server of
  its version and dumps it again (`roundtrip<v>.sql`);
- `handwritten/handwritten8.4.sql`, `handwritten9.7.sql`: what a person writes and a dump never does (no database
  named, keys on columns, `CREATE INDEX`, views made again, an `ALTER TABLE`, accounts and grants, a resource group, a
  server, a foreign key outside the schema; a JavaScript library and function, a loadable function, `REFERENCES` on a
  column), and `written<v>.sql`, the same as this engine writes it;
- `lending/source.sql`: a lending library laced with stored programs and holding every type MySQL has: 16 tables (a
  table for each family of types, every spatial type, list and range-columns partitions, 5 foreign keys), 4 functions,
  5 procedures (`IN`, `OUT`, `INOUT`, cursors, handlers, transactions), 10 triggers, 4 events, 5 views (a common
  table expression, a check option), and a table of what MySQL rewrites as it reads it (`serial`, `BINARY`,
  `ASCII`, `year(4)`, `text(N)`, `blob(N)`, escapes); its procedures and triggers run as it loads. `source97.sql` adds a vector table
  with a foreign key on its column.

The tests:

- `tests/conformance.rs`: the conformance kit on all 22 samples, the canonical ones written back exactly;
- `tests/dumps.rs`: every dump read whole and written back as itself; each re-dump the same schema as the original's
  dump; the hand-written DDL read as a person meant it, its password nowhere;
- `tests/addon.rs`: an add-on's types read, written and conforming;
- `tests/live.rs`: against MySQL 8.0, 8.4, 9.7 and 26.10 in Docker (`cargo test -p schema-forge-mysql --test live --
  --ignored`): the five steps passed, a wrong password failing at sign in, an account without the rights failing at
  rights and naming them, root warned that it can change things, and the live read the same schema as the dump; and
  the lending library, on 8.4 and on 9.7, loaded, its quirks read and written by the engine and made by MySQL into
  the same table, a column of every type the version has, read live and from its dump
  as one schema, written, loaded into a fresh server, dumped again as the same schema, its procedures and triggers
  still lending and refusing as they should;
- the unit tests of each part: the splitter, the tokens, every column and table clause, views and stored programs,
  accounts, versions, types, checks.
