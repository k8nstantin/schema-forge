# Engines: every database is a plugin

The design to agree before any code. It decides whether Schema Forge can grow: MySQL, PostgreSQL and Apache Iceberg
today; BigQuery, Snowflake, ClickHouse and Iceberg format 4 next. Get it wrong and every new database or version
spreads through the whole code and becomes a mess no one can untangle. Get it right and a new database is one new
plugin, and a new version of a database touches only that database's plugin.

## The rule: the process is shared, the database is not

Schema Forge has two layers, and they never mix.

**The process, shared by every database.** How an architect works: Home, a new schema, opening a file, the Tables,
Categories, Map and Rules perspectives, the type palette and the edit forms as components, turns, undo, history,
references (`@orders.id`), the store, the MCP, and the rules machinery (linking rules, hard and soft, exceptions, the
agent's proposals and their verification). None of it knows any database.

**The database, owned by its engine plugin.** Everything that differs between databases: table kinds, data types,
keys and constraints, indexes, defaults, options, partitioning and order, sequences and user types, views, the
operations that change any of them, the checks and rules about them, the SQL they are written in, how they are read in
from files or a live database, and the versions they came in. Choosing MySQL loads MySQL's definition of all of these;
choosing Iceberg loads Iceberg's: no indexes and no enforced keys, but identifier fields, partition transforms and
field ids.

A test on a database's name outside its own plugin is a bug. No shared type, structure or function branches on the
database.

## What others did

The open-source tools that support many databases, read in their code:

| | How they split databases | Taken | Avoided |
|---|---|---|---|
| **DBeaver** | each database a plugin, in two parts (core and UI); the core part owns its object model (`MySQLTable`, `MySQLTableIndex`, `MySQLPartition`) and an editor for each kind of object | the engine owns its objects whole, and the editors for them | |
| **Bytebase** | each engine a package that registers its functions by engine: reading, writing definitions, diffing, each review rule (engine × rule); per-engine tests on recorded fixtures | a registry for each concern; rules implemented per engine; per-engine fixtures | one shared metadata structure holding every engine's fields |
| **Atlas** | a shared relational core (table, column, index, foreign key), an open list of attributes, and types each driver implements | types the driver's own; drivers registering themselves | a relational shared core: it holds because its databases are all relational, and leaks with Iceberg |
| **Prisma** | one `Connector` trait in Rust: native types per database, validation hooks | the trait and its hooks | a closed list of databases and `is_sql()` / `is_mongo()` in the core; a growing list of capability flags. Adding a database still edits the core |
| **sqlglot** | dialect classes over one syntax tree, registered automatically | automatic registration | dozens of `SUPPORTS_…` flags piling up in the shared class |
| **Liquibase** | shared type classes that branch on the database | | the mess: one `BigIntType` with `instanceof` checks for about twelve databases |

So: the engine owns its objects and types whole (DBeaver); each concern has its own registry (Bytebase); databases
are ids, not a closed list in the core, and the core never tests capability flags (Prisma, sqlglot); no shared type
branches on the database (Liquibase).

## The shared model is a skeleton

The core holds only what every database has, and holds it the same way for all:

- a **schema**: its name, its engine and the engine's version;
- **namespaces**: a path of names (a MySQL database, a PostgreSQL schema, an Iceberg namespace of any depth); the
  engine names the level and says how deep it goes;
- **objects**: an id, a kind the engine defines (a MySQL table, a PostgreSQL partitioned table, an Iceberg table, a
  view, a sequence), a namespace, a name, a comment, notes, tags and an area;
- **columns**: an id, a name, null or not null, a comment; their **type is the engine's**;
- **links** between columns, for the Map; whether a link is an enforced foreign key is the engine's;
- and on each of them **the engine's own section**: the engine's data, stored and versioned by the core without the
  core reading it.

```json
{
  "format": 2,
  "engine": { "id": "iceberg", "version": "3" },
  "namespaces": [{ "id": "ns_sales", "path": ["lake", "sales"] }],
  "objects": [{
    "id": "t_orders", "kind": "table", "namespace": "ns_sales", "name": "orders",
    "columns": [
      { "id": "c_orders_id", "name": "id", "null": false, "type": "long", "engine": { "field_id": 1 } },
      { "id": "c_orders_at", "name": "placed_at", "null": false, "type": "timestamptz", "engine": { "field_id": 2 } }
    ],
    "engine": {
      "identifier_fields": ["c_orders_id"],
      "partition_spec": [{ "source": "c_orders_at", "transform": "day" }],
      "properties": { "write.delete.mode": "merge-on-read" }
    }
  }]
}
```

A column's type is held as the engine writes it (`long`, `decimal(18,2)`, `varchar(200)`, `int unsigned`), with any
structure the engine needs in its section; only the engine parses it, checks it and tells what it means.

## The engine owns the rest

Each engine is a crate with the same layout, one module per concern, so a contributor always knows where a thing
goes and concerns never bleed into each other:

| Module | What it owns |
|---|---|
| `versions` | the engine's versions, and the version each feature below came in or went out |
| `types` | every type: name, group, plain meaning, example, parameters; reading a type as text, writing it, checking it |
| `objects` | its kinds of object (table kinds, views, sequences, user types) and what each holds |
| `keys` | primary keys, uniques, checks, foreign keys and whether they are enforced; Iceberg identifier fields |
| `indexes` | index kinds and methods, where the engine has them |
| `options` | the options of a schema, a namespace, an object and a column: kind, allowed values, default |
| `partitions` | how a table is partitioned and ordered: Iceberg transforms and sort order, MySQL range, list and hash, PostgreSQL declarative partitions, clustering |
| `operations` | the changes it adds to the shared ones (`add_index`, `set_identifier_fields`, `set_partition_spec`, `set_engine`), each with its input, its check and its effect |
| `checks` | what makes a schema wrong for this engine |
| `rules` | its rule packs, and its implementation of shared rule ideas |
| `read` | its files: telling them apart, reading a dump, definition files or a folder, with a report that adds up |
| `live` | the database itself: the fields a connection needs, reading it read-only |
| `write` | an object's definition, the whole schema, and later migrations |
| `queries` | the SQL a view is written in: what a query reads |
| `ui` | descriptors for the shared screens: palette groups, option forms, the sections a table shows, labels (`database` or `schema` or `namespace`) |
| `portable` | its types as portable types and back, with what is lost each way |

### Versions

Every type, kind, option, transform and operation says the version that brought it (and the one that took it away).
A schema is designed for one version and is offered exactly that version's features; moving a schema to another
version is an operation the engine checks. Iceberg format 4 is a new version in the Iceberg plugin and the features
it brings, nothing else.

### Operations

The shared operations are the skeleton's: add, rename, move, drop and comment namespaces, objects and columns; set a
column's null and its type (as text the engine checks); link columns. Everything else is an engine operation, declared
with its input. The agent's MCP tools and the canvas's edit forms are built from those declarations, so a new engine
brings its own operations to both without either changing.

### Rules

The machinery is shared: packs, links, hard and soft, exceptions, the agent's proposals, verification. A rule idea
that holds for several engines ("every table has a key") is one rule in the catalog, implemented by each engine in its
own way: a primary key in MySQL, identifier fields in Iceberg. An engine's own rules (MySQL's storage engine and
charset, PostgreSQL's identity columns, Iceberg's format and merge-on-read) live wholly in the engine. An engine with
no implementation of a rule says so; the rule is not offered for its schemas.

### The screens

The screens are shared and draw what the engine describes: the palette groups and types, the forms for its options
and operations, the sections of a table (keys, indexes, partitioning), the labels. Nothing in the canvas names a
database. An engine that needs a panel the descriptors cannot describe ships it as its own component, registered like
the rest.

## Plugging in

```rust
pub trait Engine: Send + Sync {
    fn id(&self) -> &'static str;                         // "iceberg"
    fn name(&self) -> &'static str;                       // "Apache Iceberg"
    fn versions(&self) -> &[Version];
    fn types(&self) -> &dyn Types;                        // every engine has types

    // The rest is optional: None until the engine has it. A facet added to the
    // interface later comes with a default, so engines built before it still build.
    fn objects(&self) -> Option<&dyn Objects> { None }
    fn keys(&self) -> Option<&dyn Keys> { None }
    fn indexes(&self) -> Option<&dyn Indexes> { None }
    fn options(&self) -> Option<&dyn Options> { None }
    fn partitions(&self) -> Option<&dyn Partitions> { None }
    fn operations(&self) -> Option<&dyn Operations> { None }
    fn checks(&self) -> Option<&dyn Checks> { None }
    fn rules(&self) -> Option<&dyn Rules> { None }
    fn read(&self) -> Option<&dyn Read> { None }
    fn live(&self) -> Option<&dyn Live> { None }
    fn write(&self) -> Option<&dyn Write> { None }
    fn queries(&self) -> Option<&dyn Queries> { None }
    fn ui(&self) -> Option<&dyn Ui> { None }
    fn portable(&self) -> Option<&dyn Portable> { None }
}
```

The facets are asked questions, never tested as flags: the core asks the engine "may this table have an index?" and
the engine answers from its version, instead of the core reading a `supports_indexes` flag and deciding itself.

Engine ids are strings. The engines Schema Forge ships with are registered in one place, and nothing else lists them:

```rust
pub fn engines() -> Registry {
    Registry::new()
        .with(schema_forge_postgres::Postgres)
        .with(schema_forge_mysql::Mysql)
        .with(schema_forge_iceberg::Iceberg)
}
```

Rust has no stable way to load compiled plugins at run time, so engines are built in: adding one is a crate and a
line. Engines in other languages, run as their own process and spoken to as JSON over the same interface, can come
later without changing it.

## The crates

The workspace says the design in its folders: `crates/` holds what every database shares, `engines/` one crate per
database, `tools/` the checks of the code itself.

| Crate | Folder | Role | What it is |
|---|---|---|---|
| `schema-forge-model` | `crates/model` | model | the skeleton: no database in it |
| `schema-forge-engine` | `crates/engine` | interface | the plugin interface: the trait and its facets, the read report, the registry, the conformance kit |
| `schema-forge-sql` | `crates/sql` | helper | reading SQL statements and tokens with `sqlparser`, for the engines that want it |
| `schema-forge-postgres`, `-mysql`, `-iceberg` | `engines/<database>` | engine | the engines, each with the same modules |
| `schema-forge-portable` | `crates/portable` | interface | the portable types engines map to, for moving between engines |
| `schema-forge-engines` | `crates/engines` | registry | the engines Schema Forge ships with, registered |
| `schema-forge-store`, `-ops`, `-rules`, `-serve`, `-mcp`, `-cli` | `crates/…` | app | the store, the operations, the rules machinery, the server, the MCP, the command line: they ask the registry |
| `schema-forge-architecture` | `tools/architecture` | tool | the design, checked on the code |
| the canvas | `canvas/` | | shared screens, drawn from the engines' descriptors (`/api/engines`) |

## The design is checked on the code

Every crate declares its role in its `Cargo.toml`:

```toml
[package.metadata.schema-forge]
role = "engine"
database = "mysql"
```

`tools/architecture` runs with every `cargo test`, in CI too, and fails the build when the design is broken:

| Role | May depend on |
|---|---|
| model | nothing of ours |
| interface | the model |
| helper | the model, the interface |
| engine | the model, the interface, helpers; **never another engine** |
| registry | the interface, the engines |
| app | the model, the interface, the registry, other apps; **never one engine** |
| tool | anything |

And besides what each role may depend on:

- **A database is named only in its engine.** In every crate but the engines and the registry, a word that is a
  database (`mysql`, `PostgreSQL`, `pg_dump`, `IcebergTable`…) fails the build. A comment counts too: an example in the
  model that names a database is a database's knowledge in the wrong place.
- **Parsing SQL belongs to engines.** Only engines and helpers may use `sqlparser`.
- **Engines live in `engines/` and say their database**; nothing else lives there.
- **Every crate declares a role**; a crate without one fails the build.

The check has its own tests, which break each rule on purpose, so it can never pass by checking nothing.

## Reading in

| Engine | Files | Live |
|---|---|---|
| PostgreSQL | `pg_dump --schema-only` | the system catalogs, read-only |
| MySQL | `mysqldump --no-data` | `information_schema`, read-only |
| Iceberg | Spark SQL definitions, one file or a folder; a warehouse of `metadata.json`, each table's current metadata with its exact field ids, partition spec, sort order, properties and format version | an Iceberg REST catalog (Polaris, Nessie, Snowflake Open Catalog, Unity, AWS Glue, BigLake), or the metadata in a bucket |

A `metadata.json` describes one table; the catalog only says which one is current (in a warehouse folder, the version
in `version-hint.text`, else the highest). Credentials for live reading come from the machine (`~/.pgpass`,
`~/.my.cnf`, gcloud application default credentials, an AWS profile), are never stored in the workspace and never
seen by the agent. Every read, of a file or a database, accounts for everything it read, and the counts add up.

## Parsing SQL

Every engine parses SQL with `sqlparser` (Apache DataFusion's parser, pure Rust), in its own dialect: MySQL,
PostgreSQL, Databricks for Iceberg's Spark SQL, BigQuery and the others it has. Dumps are read with its tokenizer and
the engine's own reader on top, so a clause the model does not describe is kept as written instead of failing the
statement; view queries are read with its full parser. The statement splitter and token cursor that do this are a
small helper crate engines may use. The core parses no SQL. Iceberg's `metadata.json` is JSON, read with the engine's
own types written from the Iceberg spec.

## Moving between engines

The only place engines meet. Each engine maps its types to a small set of portable types and back, saying what is
kept, widened, narrowed, approximated or lost. Comparing or converting any two engines (MySQL to Iceberg through
Debezium, PostgreSQL to MySQL) goes through it, so a new engine is comparable with every other once it maps its own
types, and no map is written for a pair.

## Adding an engine

1. Make `schema-forge-<engine>`, depending on `schema-forge-engine`, with the modules above.
2. Implement `Engine`: versions and types first, then the facets the database has.
3. Give it sample files and fixtures, and run the conformance kit: every type writes and reads back the same; every
   type has a portable type; every option's default is valid; the samples read and write back to the same model; every
   read's counts add up; every feature's version is one the engine has; every rule it implements runs on its samples.
4. Register it in `schema-forge-engines`.

The screens, the agent, the rules and the store pick it up from there.

Adding an engine is how Schema Forge grows, so it gets a full guide, `docs/writing-an-engine.md`, and a template
crate to start from: each facet explained with a worked example from a shipped engine, the conformance kit, the
fixtures, and how to propose an engine upstream. Every step that changes the interface updates the guide in the same PR,
so the guide is never behind the code.

## Building it

The prototype (the tag [`prototype`](https://github.com/k8nstantin/schema-forge/tree/prototype)) proved Schema Forge
can be built: the canvas from the designs, the rules engine, the agent's MCP, reading PostgreSQL dumps and Iceberg's
Spark SQL. The product is built new, to this design, from an empty tree; the prototype is reference and test
material, never code to wrap or move. Each step is one issue, one branch and one PR, in the milestone
[Engine plugins](https://github.com/k8nstantin/schema-forge/milestone/7):

1. **The foundation** (#57): the prototype tagged and cleared, the workspace laid out, the design checked on the code.
2. **The model** (#58): the skeleton with engine sections.
3. **The engine interface** (#59): the trait and its facets, the registry, the conformance kit; the guide starts.
4. **PostgreSQL** (#60, #61): its model and reading `pg_dump`; then writing.
5. **Iceberg** (#62, #63): its model and reading Spark SQL and a warehouse of `metadata.json`; then writing.
6. **MySQL** (#64, #65): its model and reading `mysqldump`; then writing.
7. **The store** (#66), **the operations** (#67) and **the rules** (#68) on the new model.
8. **The server, the MCP and the command line** (#69).
9. **The canvas** (#70), built from the agreed boards on the engines; then the schemas are imported with the new
   readers and checked in the browser.
10. **Portable types** (#79) and **the guide to writing an engine with its template crate** (#80).

Then, each its own issue: reading PostgreSQL, MySQL and an Iceberg REST catalog live (#72, #73, #74); BigQuery
(#75), kept for developers outside the core to prove the guide; migrations between versions of a schema.
