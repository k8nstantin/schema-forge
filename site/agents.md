# SchemaForge: the brief for coding agents

You were pointed here to understand SchemaForge or to help someone contribute to it. Read this file whole, then the files below in the order given, then report back to your human before you change anything. Everything here is read from the repository (https://github.com/k8nstantin/schema-forge, branch main); the files are the authority, this brief only orders them.

## If you were pointed at a task file

Stop reading this brief. A task file (specs/tasks/*.xml) is a complete instruction: follow its start element exactly, from a new session, as the root's method says. Nothing here adds to or overrides it.

## What SchemaForge is

An open-source schema designer where a coding agent and an architect work on the same live design through MCP, and nothing lands unchecked. Every database is an engine plugin; at the centre stands the database SchemaForge keeps its work in: one PostgreSQL database per schema, in the PostgreSQL 18 bundled with the app, holding the cortex every engine shares and each engine's own tables, each owner in its own namespace, designed before any of it is built and locked so every build falls into it.

## Read, in this order

1. [specs/root.xml](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/specs/root.xml): identity, authority (which files decide), method (how every task is built), the sequence of tasks and every decision with its date.
2. [specs/rules.xml](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/specs/rules.xml): every rule, where it comes from, and what catches a breach.
3. The files that decide, as the root's authority lists them:
   - [schema/cortex/](https://github.com/k8nstantin/schema-forge/tree/main/schema/cortex): every table of the namespace cortex, which every schema's database holds whatever its engine: the schema's identity, its object kinds and the parts each may have, namespaces, objects, columns, relationships, subject areas, the shared section layout as tables (table keys, check constraints, indexes, partitionings, sort fields, view queries, sequences, composite types, routines, triggers, scheduled events, verbatim statements, required extensions), the id counters and the log (turns, operations, row and value changes, locked versions); one CREATE TABLE statement per file, named after its table, every column commented on its line and the same words in its COMMENT ON statements; enforce_rules.sql, the functions that make a rule view a trigger; rules/, one view per rule, broken_<rule>, the rows breaking it
   - [schema/workspace/](https://github.com/k8nstantin/schema-forge/tree/main/schema/workspace): every table of the namespace workspace in the workspace's database (sf_workspace): the workspace, its schemas by their stable id, the saved connections, their values (never a secret), their tests and their steps; one CREATE TABLE statement per file
   - [engines/<engine>/schema/](https://github.com/k8nstantin/schema-forge/tree/main/engines): an engine's own tables, in the namespace engine_<engine> (engine_mysql.table_options), each referring to the cortex row it belongs to; its rules/; created in a schema's database whose engine it is, and in no other
   - [docs/owner-template/](https://github.com/k8nstantin/schema-forge/tree/main/docs/owner-template): the shape of every owner's folder (an engine's, a feature's, and the cortex's and the workspace's alike): its owner.toml card, the five shapes of a table, its rules/, seeds/ and migrations/, a rename in two versions
   - [postgres/manifest.toml](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/postgres/manifest.toml): the PostgreSQL the store bundles: its sources, pinned, and the programs built from them, by checksum
   - [crates/model/](https://github.com/k8nstantin/schema-forge/tree/main/crates/model): the model: Schema, Namespace, Object, Column, Link, Area, Id
   - [crates/engine/](https://github.com/k8nstantin/schema-forge/tree/main/crates/engine): the engine interface (Engine and its parts), the section layout (crates/engine/src/sections.rs), the registry and the conformance kit
   - [engines/mysql/](https://github.com/k8nstantin/schema-forge/tree/main/engines/mysql): the MySQL engine: its versions, types, kinds, options, readers and writer
   - [docs/engines.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/engines.md): the plugin design: what is shared and what is each engine's, the crates and their roles
   - [docs/connections.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/connections.md): connections: what an engine declares, profiles without secrets, the five test steps
4. The task files, in the order they are built:
   - t01 spec check (SF-93): [specs/tasks/SF-93.xml](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/specs/tasks/SF-93.xml). The spec check, in Rust: every spec file has its shape, every quote is verbatim, every path exists; every owner's folder (the cortex, the workspace, every engine, every feature, the owner template) has its shape: table files in its namespace with their comments in the database, rules, seeds, migrations; and every folder loads on PostgreSQL 18, its versions giving exactly its files. Its mutation tests plant each defect and prove the check names it.
   - t02 tables interface (SF-94): [specs/tasks/SF-94.xml](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/specs/tasks/SF-94.xml). The part of the engine interface the database needs, with no database in it: typed values and rows; a schema as the cortex's rows and back; the numbered ids and their counters; an engine's own tables, rules, seeds and migrations as data, its options as its rows and back; the kit's checks of an engine's tables.
   - t03 quill (SF-95): [specs/tasks/SF-95.xml](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/specs/tasks/SF-95.xml). Quill, the made-up engine built unlike MySQL, with its own namespace and tables; the registry of the shipped engines and, for tests, Quill beside them; the guard that shared code names no engine's words.
   - t04 mysql tables (SF-96): [specs/tasks/SF-96.xml](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/specs/tasks/SF-96.xml). MySQL's tables: every MySQL option in the rows of engine_mysql's tables, and back, for every sample; the kit requires tables of an engine that reads.
   - t05 postgres: [specs/tasks/t05-postgres.xml](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/specs/tasks/t05-postgres.xml). PostgreSQL 18 with pgvector, built by the project's CI from the official source for every platform it ships on, published as release assets, pinned by a manifest of checksums; the fetch tool every release, developer and test uses, refusing anything whose checksum differs.
   - t06 store (SF-97): Not written yet: the store over the bundled PostgreSQL (the workspace's cluster, its database and one database per schema, versions and seeds, a schema read in as one import turn with its log and read back the same, the saved connections). Written once t05 is merged, on its programs, by the decisions postgresql-bundled to parameters-not-code.
   - t07 operations: Not written yet: every change as an operation of its turn, undo and reject by the inverses the log records.
   - t08 server: Not written yet: the server over the store, its API written first, the MCP's tools among it.
   - t09 canvas: Not written yet: the canvas over the server, every flow a browser test on every engine.
5. [specs/lessons.xml](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/specs/lessons.xml): what each build taught.
6. The design for people, read after the authority and never instead of it:
   - [docs/cdc.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/cdc.md)
   - [docs/connections.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/connections.md)
   - [docs/engines.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/engines.md)
   - [docs/market.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/market.md)
   - [docs/perspectives.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/perspectives.md)
   - [docs/rules.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/rules.md)
   - [docs/store.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/store.md)
   - [docs/versions.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/versions.md)
   - [docs/writing-an-engine.md](https://raw.githubusercontent.com/k8nstantin/schema-forge/main/docs/writing-an-engine.md)
7. The code as merged, when you need it: [crates/](https://github.com/k8nstantin/schema-forge/tree/main/crates), [engines/](https://github.com/k8nstantin/schema-forge/tree/main/engines), [tools/](https://github.com/k8nstantin/schema-forge/tree/main/tools).

## The database at the core

Every table is a file of an owner's folder, one CREATE TABLE each, every column commented, its comments also in the database. Read a folder's files to know its tables; the owner template explains the shapes.

- [schema/cortex/](https://github.com/k8nstantin/schema-forge/tree/main/schema/cortex)
- [schema/workspace/](https://github.com/k8nstantin/schema-forge/tree/main/schema/workspace)
- [engines/mysql/schema/](https://github.com/k8nstantin/schema-forge/tree/main/engines/mysql/schema)
- [engines/quill/schema/](https://github.com/k8nstantin/schema-forge/tree/main/engines/quill/schema)

## Still open

These are decided by the maintainer in a design session, never by an agent. Do not build around them:

- **operation-kinds** (before t07): The operation kinds (add_table, rename_column and the rest), what each changes and how the agent calls it.
- **agent-turn-landing** (before t07): Whether an agent's change enters the current model as it is made, the turn open until a verdict, or is staged until accepted.
- **rules-tables** (before t07): The tables of the rules: their links on the hierarchy, groups, exceptions, packs and findings (docs/rules.md), in the workspace's database and the schemas' databases.
- **pipelines-tables** (before t08): The tables of a CDC pipeline between two schemas, by their stable ids.
- **insight-layer** (before t08): What is worked out about the model, kept apart from it in a feature owner insight, so a person or an agent can search and question a design through the MCP: dependencies (calls, reads, writes, foreign keys, with evidence and unresolved names) for impact walks; cards composed mechanically from the model; annotations an agent writes, with the model and the input hash; embeddings (pgvector, HNSW) of cards and annotations, searched together with full-text and exact names and every hit confirmed against the model. Kept fresh from the log: an accepted turn's row_changes name the objects whose rows are redone. Rebuilt, never logged or migrated. The MCP's read tools: search (finds candidates), object (one object whole), impact (the walk), sql (every count and list, as a read-only role). The embedding model is the decision embedding-models. A semantic layer (business terms, measures) is authored, so it is its own owner, logged by turns; its embeddings are insight's.
- **api-contract** (before t08): The server's API over the store: every route and type, written before it is built.

## The rules you work under

Every rule of specs/rules.xml binds you. In short:

- **the-schema-decides**: The schema folders (schema/cortex, schema/workspace, engines/<engine>/schema, features/<feature>/schema) are the database. Code reads and writes the tables they declare, with the columns they declare, and nothing else; no code creates, alters or drops a table, a column, an index or a constraint but the store, which does it from these files alone, and no code works out at run time what a file declares. A table, a column or a value the schema has no place for is a stop, not a workaround.
- **the-database-enforces**: Every reference between rows is a foreign key, every value is constrained by its type and its checks, and every rule a foreign key cannot state is a rule view of its owner's rules folder (broken_<rule>, the rows breaking it), which cortex.enforce_rules turns into deferred constraint triggers: the database itself refuses any commit that breaks one, whatever code or tool wrote it. Nothing is checked by convention alone, and no code turns a check off, disables a trigger or sets session_replication_role.
- **cortex-and-engines**: What every engine shares is the cortex's; what is one engine's alone is that engine's, in its own tables in its own crate, in its own namespace engine_<engine> (engine_mysql.table_options). Shared code (the model, the interface, the store, the server, the canvas) never names an engine, an engine table or an engine column; an engine never writes a cortex table's rows but through the interface, and never another engine's.
- **the-schema-grows-by-versions**: The schema grows by versions, never by rewrites. A new feature is a new owner with its own namespace, folder, versions and rules, and never changes the cortex's tables; a change to a table adds, and a rename or removal takes two versions, the data moved in the first. No version is ever edited once shipped: its checksum refuses it.
- **nothing-hardcoded**: A value a person may want changed (a name, a label, a limit, a default, a link) is a row of workspace.parameters, read at run time; code holds only the key. A new value ships as a seed of a new version, inserted where its key is missing and never over a changed one.
- **nothing-lost**: A schema written into the store and read back is the same schema: every part, every value, every order. What the model does not describe is kept exactly as written and written back in its place. Nothing is dropped, truncated, defaulted or summarised on the way in or out.
- **log-never-edited**: The log (turns, operations, row_changes, value_changes, versions) is appended to and never updated or deleted, but a turn's state and its verdict; a change to the current model is written in the same transaction as the operation that records it, with every row and value it changed.
- **engine-neutral-shared-code**: Shared code shows what an engine declares and never assumes one: no engine's connection field, kind, option, table or column is named in it. Every test of shared code runs on every engine of the test registry, and Quill, built unlike MySQL on purpose, is one of them; what each engine is tested on is data.
- **one-agent**: One session, one agent, sequential: the agent that holds a task does every step itself. It never spawns, delegates to or messages another agent, subagent or session, and never asks another model to build or verify a part.
- **agent-decides-only-what-is-listed**: A task file lists under agent-decides the only things its agent decides: the names and the decomposition of private code inside the files it owns, the standard means of a step, the contents of its fixtures within the cases listed, its commit granularity. Everything else is written in the task file, the root, these rules, the schema folders or the merged code; a build that decides anything else is closed, and the step it departed from is named in the review.
- **no-attribution**: No commit, branch, PR, file or comment carries an attribution to a coding agent or a model: no co-author line, no generated-by line, no trailer. The work is the operator's.
- **one-check**: tools/check.sh is the one command every change passes, the same locally and in CI: formatting, lint, every test (the kit, the architecture check and the spec check among them). Nothing is done until it passes; its last line is in the PR.
- **kickoff**: A build starts with a model pointed at one task file, specs/tasks/<file>.xml, as the first message of a new session on a checkout of the head of main updated from origin; nothing else is said. A session that holds anything before that line beyond what the harness gives every session (its own text, CLAUDE.md, its settings) stops, says so and builds nothing. The task file's start element names the branch, the PR title and the read order; the agent writes its own label.
- **every-rule-binds**: Every rule here binds every task, whether or not a gate of the task names it.

## When you help someone contribute

- Report what you understood first, in your own words, and ask your human what they want to do.
- Start from an issue (https://github.com/k8nstantin/schema-forge/issues, *good first issue* for a start) or a question in Discussions (https://github.com/k8nstantin/schema-forge/discussions). Larger work is agreed with the maintainer before code, often as a task file.
- Never change specs/, an owner's folder (schema/, engines/*/schema, features/), owner.toml or postgres/manifest.toml: they change only in a design session with the maintainer.
- One issue, one branch, one pull request; `tools/check.sh` passes before you push (it needs Docker).
- No attribution of any kind in commits or pull requests: your human is the author, and answers for every line.
- Ask your human before you open an issue, push, comment or open a pull request: those speak for them.
