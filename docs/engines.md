# Engines: every database is a plugin

The design of Schema Forge as a product, and every decision behind it. It decides whether Schema Forge can grow:
MySQL, PostgreSQL and Apache Iceberg first; BigQuery, Snowflake, ClickHouse, Iceberg format 4 and whatever comes next
after. A new database is one new plugin; a new version of a database touches only its plugin; and people add onto a
plugin without forking it.

## Where we are

The prototype proved Schema Forge can be built: the canvas from the designs, the rules engine, the agent's MCP,
reading PostgreSQL dumps and Iceberg's Spark SQL. It is kept as the tag
[`prototype`](https://github.com/k8nstantin/schema-forge/tree/prototype). The product is built new, to this design,
from an empty tree; the prototype is reference and test material, never code to wrap or move.

## The decisions

### 1. The process is shared; the database is its engine's

Two layers that never mix. **The process** is how an architect works, and every database shares it: Home, a new
schema, opening a file, the Tables, Categories, Map and Rules perspectives, the palette and the edit forms as
components, turns, undo, history, references (`@orders.id`), the store, the MCP, and the rules machinery (linking,
hard and soft, exceptions, the agent's proposals, verification). **The database** is everything that differs between
databases (table kinds, types, keys, constraints, indexes, defaults, options, partitioning, order, the operations
that change them, the rules about them, the SQL they are written in, how they are read in) and it belongs to its
engine plugin. A schema chooses its engine first; everything follows from it.

### 2. The shared model is a skeleton

`schema-forge-model` holds only what every database has, the same way for all: a schema (its engine and the engine's
version), namespaces nested by parent, objects (an id, a kind the engine defines, a name, a comment, notes, tags, an
area, the objects it reads), columns (an id, a name, its type as the engine's text, null or not null, a comment), links
between columns of two objects, and areas. Every part has an id that never changes when it is renamed, and an
**engine section** the model stores and versions without reading. The file is JSON, format 2. Nothing in the model
names a database.

### 3. One layout every engine fills, and a schema of its own per engine

So that no engine grows a storage of its own, every engine's sections follow **one layout**
(`schema_forge_engine::sections`), the template: a table's `keys` (primary, unique, identifier), `checks`, `indexes`,
`partitioning`, `partition_of`, `order`; a view's `query`; a `sequence`; the schema's own types (`values`, `domain`,
`fields`); a `routine` (a procedure or function: its parameters, what it returns, its language and characteristics),
a `trigger` (its timing, the changes it fires on, the table it is on), an `event` (its schedule), each with its body
exactly as written; a column's `default`, `identity`, `generated`; a link's `enforced`, `on_delete`, `on_update`, `match`,
`deferrable`; the schema's `format` (the engine's storage version, for upgrades), `kept` (what the model does not
describe, exactly as written, with where it goes back) and `requires`. An engine fills the slots its database has and
leaves the rest out. A slot the layout does not have is refused.

**Every object a database has is accounted for.** Each engine's plan inventories every kind of object its database
has, and each is modelled as a kind (visible in the canvas, referenced by the agent, open to rules) or, when it belongs
to the server rather than the schema (accounts, roles, grants), kept exactly as written and counted by kind, with the
reason in the engine's plan. Nothing is dropped, and nothing is lumped into "other" by default.

Each engine also **declares its kinds of object** and the slots each uses (a table its keys and indexes, a view its
query), so a view with partitioning or a table with a query is refused. The layout has a version; a schema written
with a later one is refused whole by an older build, never read with something dropped.

What belongs to one database alone has one home: each element's `options`. Each engine **declares its options as
data** (`schema_forge_engine::options`): for each part, every key, its kind (a flag, a whole number, a decimal, text,
one of a list),
what it means, and the versions that have it. That declaration is the engine's own schema; the conformance kit
refuses an option it does not declare, and the canvas builds its option forms from it.

| Slot | PostgreSQL | MySQL | Iceberg |
|---|---|---|---|
| `keys.primary`, `keys.unique` | ✓ | ✓ | |
| `keys.identifier` | | | identifier fields |
| `checks`, `indexes` | ✓ | ✓ | |
| `partitioning` | range, list, hash | range, list, hash, key | `day`, `bucket[16]`, `truncate[4]`… |
| `partition_of` | a partition's parent and bounds | | |
| `order` | | | the sort order |
| `options` | unlogged, tablespace, fillfactor… | engine, charset, row format… | format version, write modes… |

### 4. One crate per database, its versions inside it

Each engine is one crate, `engines/<database>`. Versions of a database share nearly everything, so they live in its
crate: its versions are a table, and every feature (a type, an option, a capability) is marked with the version that
brought it and the one that took it away. A schema is designed for one version and is offered exactly that version's
features. Iceberg format 4 is new rows in the Iceberg crate. Never a crate per version: the architecture check fails
the build when two crates say the same database.

### 5. One engine, one PR, all of it enclosed

An engine is built whole (versions, types, options, reading and writing) in one crate and one PR. Engines share
nothing with each other but the interface: no shared helper crates, so a problem in one engine is found in that
engine and never breaks another. Each parses SQL with `sqlparser` (Apache DataFusion's parser, pure Rust) directly,
in its own dialect, with its own statement reader for its own dump format. Iceberg's `metadata.json` is read with the
engine's own types, written from the Iceberg spec.

### 6. What grows is data

Inside an engine, what grows is tables, never branches: its versions and features, its types (with every spelling a
dump uses), its options, the kinds of statement it reads (a handler each, registered in one place), the kinds of
statement it keeps. Nothing tests a version number or lists types in code paths.

### 7. Add-ons: people add onto an engine without forking it

Each engine has a public add-on trait: an add-on is its own crate contributing what a database extension brings
(types; statement handlers; kinds of kept statement; later, rules), registered with one line
(`Postgres::new().with(PostGis)`). The engine's tables are built from its built-ins and its add-ons. The extensions an
engine ships support for are written as add-ons themselves: the worked examples, and the proof.

### 8. The interface grows without breaking anyone

The engine interface (`schema-forge-engine`) is one trait with a required core (identity, versions, types) and
optional parts with defaults. A part joins the interface when something first uses it, shaped by that use. Every data
type an engine makes, in the interface and the model, is made with constructors and may gain fields
(`#[non_exhaustive]`); errors may gain variants. So a part, a field or a variant added later breaks no engine and no
add-on. Engine ids are strings; the engines Schema Forge ships with are registered in one place.

### 9. Checked, not trusted

- **The conformance kit**, which every engine runs in its own tests: identity and versions; every type (its example
  reads back exactly as itself, in exactly the versions that have it, and is refused as not in the version by the
  others); every option declared, of its kind, in its versions; every section in the layout, every id a section names
  in the schema; every sample read with a report that adds up, sound, typed with the engine's own types; every object
  with a definition; a sample in the form the engine writes written back as **the same text** and read back to the
  same schema; every sample query reading what it says. Every part an engine has needs samples that exercise it.
- **The architecture check** (`tools/architecture`), run by `cargo test` in CI: every crate declares its role; roles
  depend only the way this design allows (an engine never on another; the store, server, MCP and command line never
  on one engine); a database is named only in its engine, not even inside an identifier or a comment; only engines
  parse SQL; only the query layer depends on DataFusion; one crate per database.

### 10. Reading in: files and live

Every engine reads its files (a dump, definition files, table metadata) and, with credentials, the live database.
Credentials come from the machine (`~/.pgpass`, `~/.my.cnf`, gcloud application default credentials, an AWS profile),
are never stored in the workspace, never seen by the agent, and every live read is read-only. Every read accounts for
everything it read (modelled, kept as written, or left out as data) and the counts add up; what is not understood is
kept whole, never half read, and written back in its place.

### 11. Apache DataFusion at the center, as the query layer

Every engine maps its types to **Apache Arrow's** and back (`schema_forge_engine::portable`), saying how faithful each
mapping is: exact (it comes back as the same type), approximate (the kind of value kept, a detail such as a length
lost) or lost. Arrow is the vocabulary Apache DataFusion and Iceberg's Rust library speak, and it is the one place
engines meet: any two engines are compared or converted through it, never through a map written for the pair, and a
new engine is comparable with every other once it maps its own types.

On top of it sits **the DataFusion layer** (`schema-forge-query`): a designed schema, of any engine, exposed to
DataFusion as a catalog. With it:

- a view's query is **planned**, not only parsed: each of its columns gets a type, its lineage is known (this column
  comes from `orders.total`), and whether it still works after a change is the planner's answer;
- **compatibility and conversion** between engines go through Arrow types, and queries are written for another
  engine with DataFusion's dialect unparsers;
- **live sources** come through the DataFusion ecosystem (Iceberg catalogs, community table providers for PostgreSQL,
  MySQL and others) beside each engine's own native reader, which stays the source of truth for its DDL;
- **schema management** grows from here: comparing a design with a live database, finding drift, planning and checking
  a migration before it is applied.

DataFusion is not the model: it describes tables as Arrow schemas, without lengths, unsigned integers, keys, indexes
or partitions, the fidelity a designer needs. The model and the engines keep that; DataFusion is the shared layer
that plans and connects. Engines depend on `arrow-schema` only, never on DataFusion; only the query layer does, and
the architecture check holds that. As DataFusion grows (new dialects, connectors, functions), every engine gains it
through its Arrow mapping.

## The crates

| Crate | Folder | Role | What it is |
|---|---|---|---|
| `schema-forge-model` | `crates/model` | model | the skeleton |
| `schema-forge-engine` | `crates/engine` | interface | the trait, the section layout, the option schema, the Arrow mapping, the registry, the conformance kit |
| `schema-forge-postgres`, `-mysql`, `-iceberg` | `engines/<database>` | engine | the engines, each with its add-on trait and bundled add-ons |
| `schema-forge-engines` | `crates/engines` | registry | the engines Schema Forge ships with, registered |
| `schema-forge-query` | `crates/query` | app | the DataFusion layer: a schema as a DataFusion catalog, planned views, lineage, Arrow-type compatibility, live sources |
| `schema-forge-store`, `-ops`, `-rules`, `-serve`, `-mcp`, `-cli` | `crates/…` | app | they ask the registry, never one engine |
| `schema-forge-architecture` | `tools/architecture` | tool | the design, checked on the code |
| the canvas | `canvas/` | | the shared screens, drawn from what each engine describes (`/api/engines`) |

## The plan

The plan is the build spec: [specs/root.xml](../specs/root.xml) holds the sequence of tasks, the decisions with their
dates, and the method every build follows; each task is one XML file under [specs/tasks/](../specs/tasks), one branch
and one pull request, keyed `SF-<issue>`. The database comes first: its schema folders ([docs/store.md](store.md)) are
designed and locked before any of it is built, and every task falls into them.

**Done:** the foundation, the model, the engine interface with its registry and conformance kit, the section layout,
and **the MySQL engine**, whole ([engines/mysql](../engines/mysql/README.md)).

**Next, in the spec's order:** the spec check; the tables interface; Quill, the engine every test of shared code runs
beside MySQL; MySQL's tables; PostgreSQL 18 built by the project's CI; the store on that bundled PostgreSQL; then, once their decisions are closed, the operations, the server and
the canvas. After them: the PostgreSQL and Iceberg engines, each with its own tables; schema management, CDC pipelines,
consistency, deploy.

How to write an engine: [writing-an-engine.md](writing-an-engine.md).
