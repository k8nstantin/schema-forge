# SchemaForge

**The intelligent, multi-engine schema design and management tool, with your coding agent, under standards that hold.**
Design from scratch, reverse-engineer what exists, prompt your agent and work together, or let it design while you
watch. A schema converts from one engine to another, and its intelligence (what depends on what, what it means, what is wrong) is stored with it.

AI agents now change code faster than anyone can review it, and the database schema is where their mistakes stick: a
wrong type, a missing key or a dropped column outlives every commit that caused it. Each prompt invents its own
conventions, and the same data flows from MySQL or PostgreSQL through Debezium into an Iceberg lakehouse, where one
careless change breaks the rest.

SchemaForge is an open-source, multi-engine schema design and management tool where an AI coding agent and an architect work on the same live
design, and nothing lands unchecked. The agent designs through **MCP** (the protocol agents like Claude Code use to
work with tools); the architect watches every change land on a live canvas, steers it, or edits by hand. Every change,
the agent's and the architect's, is checked against **rules**: the team's design standards, written down once.

> **Status:** being built in the open, every database a plugin. The MySQL engine works today: it reads dumps, DDL
> and live servers, and writes back SQL that loads into MySQL 8.0 to 26.10. Apache Iceberg is next, then PostgreSQL. A
> working prototype proved the whole loop (tag [`prototype`](https://github.com/k8nstantin/schema-forge/tree/prototype));
> the design is on [the site](https://k8nstantin.github.io/schema-forge/).

![Home: start a schema, open one, or manage your rules](docs/screenshots/home.jpg)

## What it does

- **An agent and an architect on one live model.** Claude Code (or any MCP agent) changes the schema one checked
  operation at a time; every change lands at once on the canvas. Point at anything (`@orders.customer_id`), paste it
  into a prompt, and the agent knows exactly what is meant. The agent's changes for one prompt form a **turn**,
  accepted or rejected whole, and never rejected when that would leave the schema broken.
- **Rules, designed ahead and enforced.** "Every table has a primary key", "money is decimal, never float", "every
  timestamp has a time zone". Rules are linked before design starts (to every schema, a schema, a namespace, a group
  of tables, or one table) and every change is checked as it happens: a **hard** rule refuses a change that breaks
  it, for the agent and the architect alike; a **soft** rule lets it land and shows the break.
- **The agent designs rules too.** It reads a schema and proposes rules with its evidence ("2 of 2 `_at` columns are
  already zoned"); the system verifies each one (is it written right, does it repeat or contradict a rule, what would
  it break); the architect approves it, hard or soft; from then on it is enforced.
- **Compatible across databases.** MySQL, Apache Iceberg and PostgreSQL first: checks name every type that would be
  lost, widened or approximated in a move between them, with the reason.
- **CDC as a goal.** Say what a schema has to do ("feed it by CDC", "land PostgreSQL in Iceberg") and SchemaForge
  shows the gap: keys Debezium can follow, identifier fields, merge-on-read, source positions, types Debezium carries
  well.
- **Starts from what exists.** It reads `mysqldump` files, hand-written DDL and the live MySQL database (the
  prototype also read `pg_dump` files and Iceberg's Spark SQL, which come back as their engines are rebuilt), and keeps
  exactly as written whatever it does not model.

## Who it is for

- **Data architects** designing a lakehouse: Iceberg tables with partition specs, identifier fields and
  merge-on-read, landed from operational databases by Debezium.
- **Application architects** who want the schema behind a service to follow the same standards every time, and to
  know before a migration what would break.
- **Schema designers and data engineers** working with a coding agent, who want the agent fast and the result
  right.
- **Platform teams** writing the standards everyone else designs under.

## See it

From the prototype; the product keeps these screens, built from the same designs.

**The agent designs; you watch, then accept or reject the turn.** The agent was asked to land a shop's orders and
customers in Iceberg through Debezium. Its tables arrived through the MCP, partitioned by day, merge-on-read, keyed
by identifier fields, with a view on top. The turn waits at the bottom.

![The agent's design, with its turn waiting](docs/screenshots/table-and-turn.jpg)

**The SQL it means**, written for the target: here Spark SQL for Iceberg.

![The table's definition in Spark SQL](docs/screenshots/definition.jpg)

**The agent proposes rules; the system verifies them; you approve.** Each proposal carries the agent's evidence
and the system's checks, and is approved hard or soft.

![The agent's rule proposals, verified and waiting for approval](docs/screenshots/review.jpg)

**The rules a schema follows, and what breaks them.** Every rule linked to the schema, how it holds, and what
passes and fails on the schema as it is now.

![The rules a schema follows, by pack](docs/screenshots/rules.jpg)

**Will it survive the move?** The PostgreSQL → Iceberg pack on a PostgreSQL schema: five columns would not cross
cleanly, each named with the reason.

![PostgreSQL to Iceberg compatibility](docs/screenshots/compatibility.jpg)

**Rule packs you add to any schema.** CDC-ready: Debezium → Iceberg, and what each of its rules asks.

![The CDC-ready rule pack](docs/screenshots/rule-packs.jpg)

**Every new schema: name, type, rules, agent.** A new schema has no rules until you add them, each pack hard or
soft.

![The new-schema wizard, choosing rule packs](docs/screenshots/new-schema-rules.jpg)

## Every database is a plugin

You choose a schema's database first, and everything follows it. SchemaForge is built in two layers that never mix:

- **The process is shared.** The screens, turns, undo, history, references, the rules machinery and the MCP work the
  same for every database and know none of them.
- **The database is its engine's.** Table kinds, types, keys and constraints, indexes, options, partitioning, the
  operations that change them, its rules, its SQL, and reading it in from a dump, definition files or the live
  database all belong to its **engine**: one plugin per database, its versions inside it: its own typed tables in
  its own namespace of the one database, its reader and writer, its own owner and service account.

### Two engines, a dozen databases

What looks like a dozen engines is two, by the design of the schema. **Two full-feature engines** are built, each
once, across every version of its database:

| Engine | Versions | Its family: subsets that fall right into it |
|---|---|---|
| `engine_mysql` | MySQL 5.7, 8.0, 8.4, 9.7 | Percona Server, Amazon RDS, Cloud SQL, Amazon Aurora, TiDB |
| `engine_postgresql` | PostgreSQL 15 to 18 | Amazon RDS, Cloud SQL, Amazon Aurora, AlloyDB, Spanner, CockroachDB |

```mermaid
flowchart LR
  subgraph MySQL family
    percona[Percona Server] --> my
    rds1[Amazon RDS] --> my
    csql1[Cloud SQL] --> my
    aurora1[Amazon Aurora] --> my
    tidb[TiDB] --> my
    my[["engine_mysql<br/>MySQL 5.7 · 8.0 · 8.4 · 9.7<br/>built"]]
  end
  subgraph PostgreSQL family
    rds2[Amazon RDS] --> pg
    csql2[Cloud SQL] --> pg
    aurora2[Amazon Aurora] --> pg
    alloy[AlloyDB] --> pg
    spanner[Spanner] --> pg
    crdb[CockroachDB] --> pg
    pg[["engine_postgresql<br/>PostgreSQL 15 to 18<br/>next"]]
  end
  my --> cortex[(the cortex<br/>what every engine shares)]
  pg --> cortex
```

The plain engine has the most features; every managed service, distribution or compatible database is a **subset**
of it, a flavor of its plugin. A subset costs facts, not code:

- **What it refuses** (a version, a kind of object, a storage engine, a privilege, an option, a name) is a declared
  fact, each from the provider's own documentation, and the database refuses it as the design is written.
- **What it adds** follows one rule: a new kind of object gets a typed table (TiDB's placement policies, Percona's
  compression dictionaries); a new option on an existing object is a declared key of that row's `flavor_options`; a
  key that points at an object, or that two flavors share, becomes a typed column.
- **A true fork** (MariaDB) becomes an engine of its own, built from its family's engine as a template by the same rule.

```mermaid
flowchart LR
  fact[a fact of a flavor,<br/>from its provider's docs] --> r{what is it?}
  r -->|it refuses something| a[a declared fact:<br/>refused as the design is written]
  r -->|a new kind of object| b[a typed table]
  r -->|a new option| c[a declared flavor_options key]
  r -->|a key that points at an object| d[a typed column, a foreign key]
```

The two families share the cortex and its principles, never their tables: PostgreSQL's engine is its own, far larger
design. Every flavor, what it refuses and the page each fact is from: [the Engines page](https://k8nstantin.github.io/schema-forge/engines.html#mysql).

### The schema is the core

The **cortex** holds what every database shares (designs, their history, and the namespaces, tables, columns,
indexes, keys and dependencies the canvas and the agent read) and the **plugs** every engine fits into. Everything
else is the **plugin's**, in its own schema `engine_<engine>`, as typed columns with checks and foreign keys. Every id
is a **UUIDv7** made with its row. Each namespace has its own two roles: `<namespace>_owner` owns it, and
`<namespace>_service` is its service account, the only writer of its tables, fenced to its own engine's designs and
holding only the privileges its work needs. Plugins share nothing with each other but the cortex: a problem in one is
found in that one and never breaks another. **Adding a database needs no change to the core.**

```mermaid
flowchart LR
  app[cortex_service<br/>the app] -->|writes| model[(the cortex model)]
  agent[cortex_agent<br/>the coding agent] -->|writes| model
  reader[cortex_reader] -.->|reads| model
  mysvc[engine_mysql_service] -->|the only writer| mytables[(engine_mysql tables)]
  mysvc -->|MySQL designs only| model
  pgsvc[engine_postgresql_service] -->|the only writer| pgtables[(engine_postgresql tables)]
  pgsvc -->|PostgreSQL designs only| model
```

A plugin is plugged in by five steps, each run as the role it belongs to:

```mermaid
flowchart LR
  s1[1 · the superuser<br/>its roles, its schema] --> s2[2 · cortex_owner<br/>its row · open_to]
  s2 --> s3[3 · its owner<br/>its tables]
  s3 --> s4[4 · cortex_owner<br/>seeds · plug_in checks]
  s4 --> s5[5 · its owner<br/>fit_plugin: grants, history, fence]
```

Every table, column and reference: [the Database page](https://k8nstantin.github.io/schema-forge/database.html).
Every decision and why: [specs/root.xml](specs/root.xml) (decisions service-plugins, plugin-package, database-roles,
plugin-writes).

## How it works

```
 you ──── canvas (browser) ────┐
                               ├──► schema-forge serve ──► the model, the rules, every change logged
 agent ── MCP (Claude Code) ───┘          │
                                          └──► checked on every change: the model's own rules, your hard rules
```

You and the agent take the same path: **schema → type → rules → design**. The agent never designs before it knows
the schema's type and has read its rules.

The prototype's MCP tools, which the product keeps:

| The agent asks for | MCP tools |
|---|---|
| the schema | `schemas`, `describe` |
| its rules | `rules` (what holds, in plain words), `check` (what breaks, hard or soft), `catalog` (every rule, and the grammar new ones are written in) |
| new rules | `propose_rules` (a new rule as a sentence, a catalog rule to link, an exception with its reason), `proposals` |
| a design | `new_schema`; `start_turn`; `change`: operations (`add_table`, `add_column`, `alter_column`, `relate`, `add_index`, `set_identifier_fields`, `set_partition_spec`, `set_property`, views, renames, drops) applied as one change, all or none; refused with the rule and the reason when it breaks a hard rule; destructive ones need a yes |

## The database at the core

**One PostgreSQL. Your design, its rules, its history and its vectors, in one place, for one person or a whole team.**

> Designed and specified ([specs/](specs/)), and being built now, in the order the spec gives.

**Visit the site:** [k8nstantin.github.io/schema-forge](https://k8nstantin.github.io/schema-forge/).

**Read the design**, with its diagrams, every table and every decision:
[Start here](https://k8nstantin.github.io/schema-forge/start.html) ·
[Engines](https://k8nstantin.github.io/schema-forge/engines.html) (the two families and their subsets; how an engine plugs in and is proven) ·
[The database](https://k8nstantin.github.io/schema-forge/database.html) (every table, and why the schema is the core) ·
[The owner template](https://k8nstantin.github.io/schema-forge/template.html) (how an engine or a feature adds its tables) ·
[The build spec](https://k8nstantin.github.io/schema-forge/build-spec.html) (how coding agents build it). Every page is generated from the repository
([docs/pages/](docs/pages/)).

- **Real PostgreSQL, bundled.** SchemaForge ships PostgreSQL 18 with **pgvector** inside the app: nothing to install,
  nothing to configure. On a laptop, each workspace runs its own private cluster behind a Unix socket. For a team, point
  it at a central PostgreSQL server: **the same code, the same schema, only the connection changes.**
- **The metadata and the vectors in one database.** Every object, column, relationship and rule sits beside its
  embedding. One SQL query can ask by meaning (*tables about billing*), by structure (*with a key to customers*) and by
  lineage (*and everything that reads them*) together, with no second store to sync and no index left out of date.
- **Fresh on every change.** The log knows exactly which objects a turn touched, so only those are embedded again. What
  the agent finds is what is on the canvas, as you draw or as it designs.
- **Guarded by the database itself.** Foreign keys, typed and checked columns, and rules PostgreSQL enforces at every
  commit hold for one user and for a hundred: two people's changes can never together break what each one kept, because
  every write runs `SERIALIZABLE`.
- **Your choice of embeddings, like your choice of server.** A model bundled and run locally, so nothing leaves the
  machine, or a remote one, an API or the team server's own, so everyone shares one model and one index.

**Point it at the database you have, and get to know it.** Read in a live database, a dump or a folder of DDL, and
SchemaForge works out what nobody wrote down: its architecture (every object, key, index and partition as one model),
its relationships (what reads and writes what, what a change would reach), its meaning (what each object is for, found
by meaning) and its problems (each a finding with its evidence). Ask in plain words, on the canvas or through your agent.

The database is **designed first and locked**, so coding agents fall into it instead of drifting from it
([docs/store.xml](https://k8nstantin.github.io/schema-forge/doc-store.html)):

- **Every owner in its own namespace.** `cortex` is thin: what every engine shares (objects, columns, keys, indexes,
  dependencies, the log), every id a UUIDv7; each engine and managed service brings `engine_<id>` (`engine_mysql.tables`); each future feature brings its own
  (`insight`, `semantic`, `rules`, `pipelines`). Nothing reaches into another owner's tables.
- **The database enforces it.** Every reference is a foreign key, every value typed and checked, every column documented
  in the database itself. Every table of a design carries its design, and every reference within it is
  `(design, column)` to `(design, id)`: no row can point into another design. A kind of object its version lacks, or its
  flavor refuses, is refused as it is written, whoever wrote it.
- **Every change is logged.** One trigger logs every row change of the cortex and of every plugin under the operation
  of a turn, before and after: undo, restore and branch switch are the same for every engine, a change outside a turn
  is refused, and nobody rewrites the log.
- **Proven, not claimed.** Every property is a tool in the repository that CI runs on every pull request: the cortex's
  load, ids, dump, history, refusals and privileges; each engine's round trip of every object of every version through
  the store, identical.
- **It grows by versions.** Each owner versions its own tables; every change adds, a rename takes two versions, and
  every release upgrades a database of every earlier version. A new database or feature starts from
  [the owner template](https://k8nstantin.github.io/schema-forge/doc-owner-template.html): five table shapes, rules, migrations, proved on PostgreSQL.
- **Ready to be talked to.** An `insight` layer (dependencies, annotations, embeddings) lets a person or an agent
  search and question a design through the MCP, in plain words.

The build itself is specified ahead: [specs/](specs/) holds the root, the rules and one XML task file per branch and
pull request, which a coding agent builds from and nothing else.

## Where it stands

**The prototype is done** (branch `prototype`): the canvas, the agent's MCP, turns and undo, the rules engine,
reading pg_dumps and Iceberg Spark SQL, and writing PostgreSQL and Iceberg SQL.

**The product is being rebuilt from the spec.** On 2026-11-27 every line of code on `main` was removed, keeping
only the spec (`specs/`, `docs/`, this site and this README). It is rebuilt in this order, one objective at a time,
each with its own issue, ETA, branch and PR, merged before the next starts and done only when its proofs pass in CI:

| # | Objective | Issue | ETA (UTC) | Status |
|---|---|---|---|---|
| 1 | The spec and README: this order, every engine a plugin, UUIDv7 everywhere | [#138](https://github.com/k8nstantin/schema-forge/issues/138) | 2026-11-27 06:00 | merged ([#147](https://github.com/k8nstantin/schema-forge/pull/147)) |
| 2 | The cortex from scratch: the plugs every engine fits into, history, the shared model, each tested by a tool | [#139](https://github.com/k8nstantin/schema-forge/issues/139) | 2026-11-28 06:00 | merged ([#148](https://github.com/k8nstantin/schema-forge/pull/148)) |
| 3 | `engine_mysql`: MySQL 5.7, 8.0, 8.4, 9.7 and its subsets Percona Server, Cloud SQL, RDS and Aurora | [#140](https://github.com/k8nstantin/schema-forge/issues/140) | 2026-11-30 18:00 | in review ([#149](https://github.com/k8nstantin/schema-forge/pull/149), CI green) |
| 4 | `engine_postgresql`: PostgreSQL 15 to 18 and its subsets Cloud SQL, RDS, Aurora and AlloyDB | [#141](https://github.com/k8nstantin/schema-forge/issues/141) | 2026-12-03 06:00 | next |
| 5 | Spanner, a subset of the PostgreSQL family | [#145](https://github.com/k8nstantin/schema-forge/issues/145) | 2026-12-04 06:00 | after #141 |
| 6 | CockroachDB, a subset of the PostgreSQL family | [#146](https://github.com/k8nstantin/schema-forge/issues/146) | 2026-12-05 06:00 | after #145 |

What objective 3 proved: every object of MySQL 5.7 to 9.7 and Percona Server 5.7 to 8.4 read from a live server,
stored, written back into a fresh server and read again, identical, on all seven servers and on two private
production schemas (2,608 and 665 objects); every fact Cloud SQL, RDS and Aurora declare refused, and what each
allows loading into MySQL 8.0.

Apache Iceberg, BigQuery, Snowflake, ClickHouse and others come after them.

To try the prototype:

```
git clone https://github.com/k8nstantin/schema-forge && cd schema-forge && git checkout prototype
(cd canvas && npm ci && npm run build)
cargo build --release
./target/release/schema-forge serve
claude mcp add --transport http schema-forge http://127.0.0.1:7410/mcp
```

`serve` opens the prototype's canvas at `http://localhost:7410`. Create a schema there, or read one in with
`schema-forge import <pg_dump or Iceberg folder> --schema <name>` or **Open a file or folder** on Home. Then ask
your agent: *"Design `@orders_lake`: orders and customers landed from the shop's PostgreSQL by Debezium."*

The design: [docs/engines.xml](https://k8nstantin.github.io/schema-forge/doc-engines.html) (engines), [docs/rules.xml](https://k8nstantin.github.io/schema-forge/doc-rules.html) (rules),
[docs/perspectives.xml](https://k8nstantin.github.io/schema-forge/doc-perspectives.html) (the canvas), [docs/cdc.xml](https://k8nstantin.github.io/schema-forge/doc-cdc.html) (CDC to Iceberg),
[docs/store.xml](https://k8nstantin.github.io/schema-forge/doc-store.html) (storage), [docs/versions.xml](https://k8nstantin.github.io/schema-forge/doc-versions.html) (versions),
[docs/market.xml](https://k8nstantin.github.io/schema-forge/doc-market.html) (how it compares).

## Contributing

**A collaborative learning exercise: data products, coding with agents and spec-driven development, learned by
building one together.** Start where you are: a question, a sample of real
DDL, or pointing your agent at the brief; the checks and a person's review catch mistakes before they land. It is built with coding agents, and contributed the same way. SchemaForge builds two things at once: the product, and
the method it is built by, where people and coding agents develop together. A design session writes the work as a
task file; one agent builds it in one session; gates and a person's review decide; a build's lesson improves the
method. You contribute exactly the way the maintainer builds, with your own agent, and the method is yours to improve
too. Everyone is welcome, and every part you touch teaches databases from the inside.

**With a coding agent?** Point it at the brief: *"Read https://k8nstantin.github.io/schema-forge/agents.xml and every
file it lists, in its order, then tell me what SchemaForge is and which task or issue fits me."* It reads the whole
spec, in order, and reports back before anything changes ([how it goes](https://k8nstantin.github.io/schema-forge/contribute.html)).

## Built with

Today: the store is **PostgreSQL 18**, and the schema is its core: plain SQL files, one per table
([schema/cortex](schema/cortex), [engines/mysql](engines/mysql)), every column commented in the database. Each engine's
reader, writer and rows module, and every tool that proves them ([tools/](tools/)), are **Python**; every check runs in
fresh **Docker** containers of each server (MySQL, Percona Server, PostgreSQL), in **GitHub Actions** on every pull
request. Next: the app over this store (the server, the MCP, the canvas), with **pgvector** for the schema's intelligence.
The prototype used Rust (**rmcp**, **axum**, **tokio**, **redb**) and a React and TypeScript canvas.

## Licence

MIT or Apache-2.0, at your choice.
