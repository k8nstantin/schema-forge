# Contributing to Schema Forge

**You are welcome here, whatever you know about databases today.** Schema Forge is a place to learn how databases
really work, from the inside, by building something people use: how MySQL, PostgreSQL and Iceberg each say what a table
is, how their types and keys and partitions differ, what their catalogs hold, how CDC carries a change from one to
another, how PostgreSQL enforces a rule at commit and searches by meaning with vectors. Every part you touch teaches one
of these, and the design is written down so you never have to guess.

## Where to start

- **Read the design**, with its diagrams: [Start here](https://claude.ai/artifact/BrFaiE6HBhVArfUGyiB3zp) ·
  [the database](https://claude.ai/artifact/3XWs1sS1cCsu3ar9F6pRos) ·
  [the owner template](https://claude.ai/artifact/XUiMve4wFDNTFZqMZnjBaC) ·
  [the build spec](https://claude.ai/artifact/2jnUargwgDpCVKgFYUbxAs). The same pages are in
  [docs/pages/](docs/pages/).
- **Read why it is built this way:** [docs/engines.md](docs/engines.md) (every database a plugin),
  [docs/store.md](docs/store.md) (the database at the core).
- **Ask.** Start a [discussion](https://github.com/k8nstantin/schema-forge/discussions) with your question; there are no silly ones. Saying what confused you is a
  contribution too: it shows where the docs are thin.

## Ways to contribute, and what each teaches

| You could | You will learn | Start from |
|---|---|---|
| **Add a database**: write an engine | that database's whole grammar, types, catalogs and quirks, and how to read a live server | [docs/writing-an-engine.md](docs/writing-an-engine.md), [engines/mysql](engines/mysql/README.md) as the worked example |
| **Add a feature's tables** (insight, a semantic layer, rules, pipelines) | relational design, foreign keys, rules as triggers, versioned migrations | [the owner template](docs/owner-template/README.md) |
| **Extend a database** (PostGIS, pgvector, a company's conventions): an add-on | how extensions change types and DDL | [docs/writing-an-engine.md](docs/writing-an-engine.md), section 12 |
| **Bring real DDL**: a dump or schema that breaks a reader | the corners of SQL nobody documents | the samples under `engines/<engine>/tests/samples` |
| **Review the spec**: a task file under [specs/tasks](specs/tasks) | how a system is designed before it is built | [specs/root.xml](specs/root.xml) |
| **Fix, test or explain**: an issue, a missing test, a clearer page | the code around it | the issues labelled *good first issue* |

## How work is done

- **One issue, one branch, one pull request**, one concern. Open the issue first and say what you propose; for anything
  larger than a fix, the maintainer and you agree the design before code (often as a task file under
  [specs/tasks](specs/tasks)), so no work is wasted.
- **The database schema is designed first and locked.** The tables under `schema/`, `engines/*/schema` and `features/`
  change only through a design session with the maintainer, as a new version that adds
  ([the owner template](docs/owner-template/README.md) shows how). A pull request that needs a table changed says so,
  and the design is settled first.
- **Every pull request passes `tools/check.sh`**: format, clippy and every test, including the **architecture check**
  (`tools/architecture`), which fails the build when a crate depends the wrong way, a database is named outside its
  engine, or engines share code. CI runs it, and `main` accepts a merge only when it passes and the maintainer has
  approved.
- **New code follows the code around it**: plain names, documentation in full sentences, no dead code, nothing
  hardcoded that should be data. Public data types are `#[non_exhaustive]` with constructors, so the interface grows
  without breaking anyone.
- **Coding agents are welcome** as your tools. You are the author of what you submit: read it, test it, and be ready to
  explain every line, as you would your own.

## Licence

By contributing you agree that your work is licensed as Schema Forge is: MIT or Apache-2.0, at the user's choice.
