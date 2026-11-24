# SchemaForge: for the coding agent opened in this repository

<!-- Rendered from specs/brief.xml, specs/root.xml and specs/rules.xml by docs/pages/build.py: edit those, never this. -->

You are in the SchemaForge repository. If the first message of this session is a task file's path, follow that file and nothing here. Otherwise this is the same brief as https://k8nstantin.github.io/schema-forge/agents.md, with the files linked where they are in this checkout.

Welcome. You have joined SchemaForge, and the person who brought you here is about to work with you on it. This brief gives you, in order, the mission, the architecture, what is needed now and how to start; then the method, everything to read, and the rules. Take it in whole, tell your human what you understood, and the two of you can start.

You were pointed here to understand SchemaForge or to help someone contribute to it. Read this brief whole, then the files it lists in the order given, then report back to your human before you change anything. Everything here is read from the repository (https://github.com/k8nstantin/schema-forge, branch main); the files are the authority, this brief only orders them.

## If you were pointed at a task file

Stop reading this brief. A task file (specs/tasks/*.xml) is a complete instruction: follow its start element exactly, from a new session, as the root's method says. Nothing here adds to or overrides it.

## The mission

An open-source schema designer where a coding agent and an architect work on the same live design through MCP, and nothing lands unchecked. Every database is an engine plugin; at the centre stands the database SchemaForge keeps its work in: one PostgreSQL database per schema, in the PostgreSQL 18 bundled with the app, holding the cortex every engine shares and each engine's own tables, each owner in its own namespace, designed before any of it is built and locked so every build falls into it.

SchemaForge builds two things together: the product, and the method it is built by, in which people and coding agents develop together: a design session fixes the database and writes a task file; one agent builds it in one session; gates and a person's review decide; a build's lesson changes the method. Every contributor works the same way, with their own coding agent, and the method is theirs to improve too.

## The architecture

How SchemaForge is put together, each part with the file that decides it. Read those files before you rely on any of this.

- **two layers** ([docs/engines.md](docs/engines.md)): The process (the canvas, the MCP, turns and undo, the rules, the store) is shared by every database and names none of them. Everything about one database (its types, kinds, options, how it is read and written, its own tables) belongs to its engine: one crate, plugged in through one interface, checked by the conformance kit and the architecture check.
- **the database at the core** ([docs/store.md](docs/store.md)): SchemaForge keeps its work in a PostgreSQL 18 with pgvector it bundles: one cluster per workspace, one database per schema. Each owner's tables are in its own namespace (cortex, workspace, engine_<id>, and a feature's own); every reference is a foreign key, every column documented in the database, and every rule a foreign key cannot state is enforced by the database at commit. Every change is an operation of a turn, logged, so it can be undone.
- **owners grow by versions** ([docs/owner-template/README.md](docs/owner-template/README.md)): The cortex, the workspace, every engine and every feature is an owner: its own folder, card, namespace, rules, seeds and versions. A change adds; a rename takes two versions. A new engine or feature starts from the owner template.
- **the repository**: crates/model, the schema skeleton every engine shares; crates/engine, the engine interface, the section layout, the registry and the conformance kit; crates/engines, the registry of the shipped engines (built by the sequence); crates/store, the store over the bundled PostgreSQL (built by the sequence); engines/<engine>, one crate per database, each with its schema folder engines/<engine>/schema; schema/cortex and schema/workspace, the cortex's and the workspace's tables; tools/architecture, the design checked on the code; tools/specs, the spec check (built by the sequence); tools/check.sh, the one command every change passes; specs/, this spec; docs/, the design for people.
- **the spec** ([specs/root.xml](specs/root.xml)): specs/ holds the root (purpose, authority, method, sequence, decisions), the rules, this brief, the lessons and one task file per build. The spec is written before the code, and the code falls into it.

## Wanted now

What is needed now, read from the root's sequence and decisions every time the brief is rendered.

**Ready to build**: Written, and every task it depends on built. Anyone may build it; the best build is merged.

- t01 · spec check: every spec file and owner folder checked, and loaded on PostgreSQL 18 (SF-93): [specs/tasks/SF-93.xml](specs/tasks/SF-93.xml), issue https://github.com/k8nstantin/schema-forge/issues/93. The spec check, in Rust: every spec file has its shape, every quote is verbatim, every path exists; every owner's folder (the cortex, the workspace, every engine, every feature, the owner template) has its shape: table files in its namespace with their comments in the database, rules, seeds, migrations; and every folder loads on PostgreSQL 18, its versions giving exactly its files. Its mutation tests plant each defect and prove the check names it.

**Queued**: Written, and waiting for the tasks before it: read it, and build it once they are merged.

- t02 · tables interface: a schema as typed rows of the cortex and back, with no database (SF-94): [specs/tasks/SF-94.xml](specs/tasks/SF-94.xml), issue https://github.com/k8nstantin/schema-forge/issues/94
- t03 · quill: the made-up engine every shared test runs beside MySQL (SF-95): [specs/tasks/SF-95.xml](specs/tasks/SF-95.xml), issue https://github.com/k8nstantin/schema-forge/issues/95
- t04 · mysql tables: every MySQL option kept in engine_mysql's tables, and read back (SF-96): [specs/tasks/SF-96.xml](specs/tasks/SF-96.xml), issue https://github.com/k8nstantin/schema-forge/issues/96
- t05 · postgres: PostgreSQL 18 with pgvector, built by our CI for five platforms: [specs/tasks/t05-postgres.xml](specs/tasks/t05-postgres.xml)

**Ahead**: Not written yet: the work after the queued tasks, each written as a task file once its decisions close. A feature you want to build may be here.

- t06 · store: the workspace kept in the bundled PostgreSQL, every import logged (SF-97): Not written yet: the store over the bundled PostgreSQL (the workspace's cluster, its database and one database per schema, versions and seeds, a schema read in as one import turn with its log and read back the same, the saved connections). Written once t05 is merged, on its programs, by the decisions postgresql-bundled to parameters-not-code.
- t07 · operations: every change an operation of its turn, undone by its inverse: Not written yet: every change as an operation of its turn, undo and reject by the inverses the log records.
- t08 · server: the server over the store: its API and the MCP's tools: Not written yet: the server over the store, its API written first, the MCP's tools among it.
- t09 · canvas: the canvas over the server, every flow tested in a browser: Not written yet: the canvas over the server, every flow a browser test on every engine.
- t10 · steward: the agent that reviews, merges the best build and starts the next: Not written yet: the XML instruction for an agent that runs on a schedule, reviews and QAs every open pull request against its task file, its gates and the rules, merges what passes, records each build's lesson, and starts the next build of the sequence.

**Needs a design session**: Waiting for a design session with the maintainer: bring your view to Discussions.

- **operation-kinds** (before t07)
- **agent-turn-landing** (before t07)
- **rules-tables** (before t07)
- **pipelines-tables** (before t08)
- **insight-layer** (before t08)
- **steward** (before t10)
- **api-contract** (before t08)

**Issues**: Smaller work, fixes and questions are issues: https://github.com/k8nstantin/schema-forge/issues, and the ones labelled good first issue are the place to begin.

## How to start

1. Read this brief whole, then the files of its reading list, in order.
2. Tell your human, in your own words: the mission, the architecture, what is wanted now, and what you think fits them.
3. Choose together: a task ready to build, an issue, a feature ahead, or a view for a design session.
4. To build a task: a new session on a fresh checkout of main, its first and only message the task file's path. For an issue or something new: open the conversation on GitHub first, with your human's word.

## The method you are joining

Every part of the product is built this way, by the maintainer and by every contributor, each with their own coding agent.

1. **design session**: A person and an agent, with the maintainer, design or change the database in the owners' folders and write the work down as a task file under specs/tasks, every decision dated in specs/root.xml.
2. **build session**: One agent, in a new session on a checkout of main, pointed at one task file and told nothing else. It reads in the order the root gives, builds only what the file says, decides only what it lists, and stops when anything is missing or two files disagree, rather than guess.
3. **gates**: Every gate of the task file runs (local, Docker, CI), and their results go into the pull request.
4. **review**: A person reviews and merges; the agent never merges.
5. **lesson**: What a build taught is added to specs/lessons.xml, and a design session changes the method or the rules because of it. The method is open to improvement like the code.

## How your human contributes through you

- **build a wanted task**: Any task listed as wanted is open to everyone at once: your human opens a new session on a fresh checkout of main whose first and only message is the task file's path (specs/tasks/<file>.xml), and submits the pull request it opens. Others may build the same task; the maintainer reviews the builds side by side and merges the best. That session is not this one.
- **bring something new**: An engine, a feature, a fix: your human opens an issue or a discussion; the design is agreed in a design session and written as a task file; then it is built as above.
- **improve the method**: A lesson, a rule that would have caught a mistake, a clearer step: proposed in Discussions, decided in a design session.

## Read, in this order

1. [specs/root.xml](specs/root.xml): identity and purpose, authority (which files decide), method (how every task is built), the sequence of tasks and every decision with its date.
2. [specs/rules.xml](specs/rules.xml): every rule, where it comes from, and what catches a breach.
3. The files that decide:
   - [schema/cortex/](schema/cortex/): every table of the namespace cortex, which every schema's database holds whatever its engine: the schema's identity, its object kinds and the parts each may have, namespaces, objects, columns, relationships, subject areas, the shared section layout as tables (table keys, check constraints, indexes, partitionings, sort fields, view queries, sequences, composite types, routines, triggers, scheduled events, verbatim statements, required extensions), the id counters and the log (turns, operations, row and value changes, locked versions); one CREATE TABLE statement per file, named after its table, every column commented on its line and the same words in its COMMENT ON statements; enforce_rules.sql, the functions that make a rule view a trigger; rules/, one view per rule, broken_<rule>, the rows breaking it
   - [schema/workspace/](schema/workspace/): every table of the namespace workspace in the workspace's database (sf_workspace): the workspace, its schemas by their stable id, the saved connections, their values (never a secret), their tests and their steps; one CREATE TABLE statement per file
   - [engines/<engine>/schema/](engines/): an engine's own tables, in the namespace engine_<engine> (engine_mysql.table_options), each referring to the cortex row it belongs to; its rules/; created in a schema's database whose engine it is, and in no other
   - [docs/owner-template/](docs/owner-template/): the shape of every owner's folder (an engine's, a feature's, and the cortex's and the workspace's alike): its owner.toml card, the five shapes of a table, its rules/, seeds/ and migrations/, a rename in two versions
   - [postgres/manifest.toml](postgres/manifest.toml): the PostgreSQL the store bundles: its sources, pinned, and the programs built from them, by checksum
   - [crates/model/](crates/model/): the model: Schema, Namespace, Object, Column, Link, Area, Id
   - [crates/engine/](crates/engine/): the engine interface (Engine and its parts), the section layout (crates/engine/src/sections.rs), the registry and the conformance kit
   - [engines/mysql/](engines/mysql/): the MySQL engine: its versions, types, kinds, options, readers and writer
   - [docs/engines.md](docs/engines.md): the plugin design: what is shared and what is each engine's, the crates and their roles
   - [docs/connections.md](docs/connections.md): connections: what an engine declares, profiles without secrets, the five test steps
4. The task files, in the order they are built:
   - [specs/tasks/SF-93.xml](specs/tasks/SF-93.xml): t01 · spec check: every spec file and owner folder checked, and loaded on PostgreSQL 18 (SF-93). The spec check, in Rust: every spec file has its shape, every quote is verbatim, every path exists; every owner's folder (the cortex, the workspace, every engine, every feature, the owner template) has its shape: table files in its namespace with their comments in the database, rules, seeds, migrations; and every folder loads on PostgreSQL 18, its versions giving exactly its files. Its mutation tests plant each defect and prove the check names it.
   - [specs/tasks/SF-94.xml](specs/tasks/SF-94.xml): t02 · tables interface: a schema as typed rows of the cortex and back, with no database (SF-94). The part of the engine interface the database needs, with no database in it: typed values and rows; a schema as the cortex's rows and back; the numbered ids and their counters; an engine's own tables, rules, seeds and migrations as data, its options as its rows and back; the kit's checks of an engine's tables.
   - [specs/tasks/SF-95.xml](specs/tasks/SF-95.xml): t03 · quill: the made-up engine every shared test runs beside MySQL (SF-95). Quill, the made-up engine built unlike MySQL, with its own namespace and tables; the registry of the shipped engines and, for tests, Quill beside them; the guard that shared code names no engine's words.
   - [specs/tasks/SF-96.xml](specs/tasks/SF-96.xml): t04 · mysql tables: every MySQL option kept in engine_mysql's tables, and read back (SF-96). MySQL's tables: every MySQL option in the rows of engine_mysql's tables, and back, for every sample; the kit requires tables of an engine that reads.
   - [specs/tasks/t05-postgres.xml](specs/tasks/t05-postgres.xml): t05 · postgres: PostgreSQL 18 with pgvector, built by our CI for five platforms. PostgreSQL 18 with pgvector, built by the project's CI from the official source for every platform it ships on, published as release assets, pinned by a manifest of checksums; the fetch tool every release, developer and test uses, refusing anything whose checksum differs.
   - t06 · store: the workspace kept in the bundled PostgreSQL, every import logged (SF-97). Not written yet: the store over the bundled PostgreSQL (the workspace's cluster, its database and one database per schema, versions and seeds, a schema read in as one import turn with its log and read back the same, the saved connections). Written once t05 is merged, on its programs, by the decisions postgresql-bundled to parameters-not-code.
   - t07 · operations: every change an operation of its turn, undone by its inverse. Not written yet: every change as an operation of its turn, undo and reject by the inverses the log records.
   - t08 · server: the server over the store: its API and the MCP's tools. Not written yet: the server over the store, its API written first, the MCP's tools among it.
   - t09 · canvas: the canvas over the server, every flow tested in a browser. Not written yet: the canvas over the server, every flow a browser test on every engine.
   - t10 · steward: the agent that reviews, merges the best build and starts the next. Not written yet: the XML instruction for an agent that runs on a schedule, reviews and QAs every open pull request against its task file, its gates and the rules, merges what passes, records each build's lesson, and starts the next build of the sequence.
5. [specs/lessons.xml](specs/lessons.xml): what each build taught.
6. The design for people, read after the authority and never instead of it:
   - [docs/cdc.md](docs/cdc.md)
   - [docs/market.md](docs/market.md)
   - [docs/perspectives.md](docs/perspectives.md)
   - [docs/rules.md](docs/rules.md)
   - [docs/store.md](docs/store.md)
   - [docs/versions.md](docs/versions.md)
   - [docs/writing-an-engine.md](docs/writing-an-engine.md)
7. The code as merged, when you need it:
   - [crates/](crates/)
   - [engines/](engines/)
   - [tools/](tools/)

## The database at the core

Every table is a file of an owner's folder, one CREATE TABLE each, every column commented, its comments also in the database. Read a folder's files to know its tables; the owner template explains the shapes.

- [schema/cortex/](schema/cortex/)
- [schema/workspace/](schema/workspace/)
- [engines/mysql/schema/](engines/mysql/schema/)
- [engines/quill/schema/](engines/quill/schema/)

## Still open

These are decided by the maintainer in a design session, never by an agent. Do not build around them:

- **operation-kinds** (before t07): The operation kinds (add_table, rename_column and the rest), what each changes and how the agent calls it.
- **agent-turn-landing** (before t07): Whether an agent's change enters the current model as it is made, the turn open until a verdict, or is staged until accepted.
- **rules-tables** (before t07): The tables of the rules: their links on the hierarchy, groups, exceptions, packs and findings (docs/rules.md), in the workspace's database and the schemas' databases.
- **pipelines-tables** (before t08): The tables of a CDC pipeline between two schemas, by their stable ids.
- **insight-layer** (before t08): What is worked out about the model, kept apart from it in a feature owner insight, so a person or an agent can search and question a design through the MCP: dependencies (calls, reads, writes, foreign keys, with evidence and unresolved names) for impact walks; cards composed mechanically from the model; annotations an agent writes, with the model and the input hash; embeddings (pgvector, HNSW) of cards and annotations, searched together with full-text and exact names and every hit confirmed against the model. Kept fresh from the log: an accepted turn's row_changes name the objects whose rows are redone. Rebuilt, never logged or migrated. The MCP's read tools: search (finds candidates), object (one object whole), impact (the walk), sql (every count and list, as a read-only role). The embedding model is the decision embedding-models. A semantic layer (business terms, measures) is authored, so it is its own owner, logged by turns; its embeddings are insight's.
- **steward** (before t10): What the steward agent may do alone and what stays a person's: which pull requests it may merge (a task's build, a contributor's, a design session's never), what its review must prove beyond the gates, how often it runs and on what, how it records a lesson, how it starts the next build, and how a person stops or overrides it. Until it closes, a person reviews and merges, and no agent merges.
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
- **kickoff**: A build starts with a model pointed at one task file, specs/tasks/<file>.xml, as the first message of a new session on a checkout of the head of main updated from origin; nothing else is said. A session that holds anything before that line beyond what the harness gives every session (its own text, the repository's agent files (AGENTS.md, CLAUDE.md, .github/copilot-instructions.md, rendered from specs/brief.xml), its settings) stops, says so and builds nothing. The task file's start element names the branch, the PR title and the read order; the agent writes its own label.
- **every-rule-binds**: Every rule here binds every task, whether or not a gate of the task names it.

## When you help someone contribute

- Report what you understood first, in your own words, and ask your human what they want to do.
- Start from an issue (https://github.com/k8nstantin/schema-forge/issues, good first issue for a start) or a question in Discussions (https://github.com/k8nstantin/schema-forge/discussions). Larger work is agreed with the maintainer before code, often as a task file.
- Never change specs/, an owner's folder (schema/, engines/*/schema, features/), owner.toml or postgres/manifest.toml: they change only in a design session with the maintainer.
- One issue, one branch, one pull request; tools/check.sh passes before you push (it needs Docker).
- No attribution of any kind in commits or pull requests: your human is the author, and answers for every line.
- Ask your human before you open an issue, push, comment or open a pull request: those speak for them.
