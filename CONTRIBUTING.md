# Contributing to SchemaForge

**SchemaForge is built with coding agents, and contributed the same way.** The project builds two things at once: the
product, and the method it is built by, where people and coding agents develop together. People decide the design,
the open questions and the review; an agent builds one task at a time, exactly as written, and stops rather than
guesses. You contribute exactly the way the maintainer builds, with your own agent, and the method is yours to improve
too. And everyone is welcome, whatever you know about databases today: every part you touch teaches how databases
really work, from the inside.

## You are welcome here: start where you are

You do not need to know all of it to make a useful first contribution: your coding agent reads the project with you,
and everyone here was new to most of it once. Mistakes are caught before they land, in three ways: the checks every
pull request runs (format, lint, every test, the architecture check and the spec check), the lock on the database's
design, and a person's review. Each step below is small, real, and teaches something; building a task or an engine
takes real skill, and these steps build it.

- **Ask a question** in [Discussions](https://github.com/k8nstantin/schema-forge/discussions): how something works, or
  why it was decided. It is answered in the open, so the next person finds it, and what confused you shows us where
  the docs are thin.
- **Tell us what your agent understood.** Point it at the brief, then post what it explained back to you and where it
  was wrong. The brief is how every agent learns the project; your report tests it, and the fix helps every agent
  after yours.
- **Bring real DDL.** Engines are proved against real schemas, not toy ones. A dump or hand-written schema of a
  database you know (schema only: no data, no secrets) becomes a sample every build of that engine must read and write
  back exactly. You learn where SQL hides its corners.
- **Fix a page or a doc.** If a sentence took you two reads, it will take the next person two reads. Rewrite it in a
  pull request: pages and docs change like code, through the checks and a review, so you learn the whole path a change
  takes.
- **Build a task.** A task file is a complete instruction: what to build, its steps, its tests and the checks that
  decide. Give it to your agent in a fresh session, review what it builds, then submit. This is where you learn the
  method end to end; others may build the same task, and the best build is merged.

Every merged contribution carries your name on GitHub, and you are thanked in the notes of the release it ships in.
We follow a [code of conduct](CODE_OF_CONDUCT.md): be kind, be patient, assume good intent.

## The method

1. **A design session**: a person and an agent, with the maintainer, design or change the database in the owners'
   folders and write the work down as a task file under [specs/tasks](specs/tasks), every decision dated in
   [specs/root.xml](specs/root.xml).
2. **A build session**: one agent, in a new session on a checkout of `main`, whose first and only message is the task
   file's path. It reads in the order the root gives, builds only what the file says, decides only what it lists, and
   stops when anything is missing or two files disagree.
3. **The gates**: every gate the task file names runs (local, Docker, CI); their results go into the pull request.
4. **The review**: a person reviews and merges. The agent never merges.
5. **The lesson**: what a build taught goes into [specs/lessons.xml](specs/lessons.xml), and a design session changes
   the method or [the rules](specs/rules.xml) because of it.

## Where to start

- **Using a coding agent?** Most people do. Point it at the brief written for agents,
  [agents.xml](https://k8nstantin.github.io/schema-forge/agents.xml): it lists the whole spec in the order to read it,
  the decisions still open, and the rules an agent works under here. Paste: *"Read
  https://k8nstantin.github.io/schema-forge/agents.xml and every file it lists, in its order, then tell me what
  SchemaForge is and which task or issue fits me; don't change anything yet."*
  ([the Contribute page](https://k8nstantin.github.io/schema-forge/contribute.html))
- **Read the design**, with its diagrams: [Start here](https://k8nstantin.github.io/schema-forge/start.html) ·
  [the database](https://k8nstantin.github.io/schema-forge/database.html) ·
  [the owner template](https://k8nstantin.github.io/schema-forge/template.html) ·
  [the build spec](https://k8nstantin.github.io/schema-forge/build-spec.html). The same pages are in
  [docs/pages/](docs/pages/).
- **Read why it is built this way:** [docs/engines.md](docs/engines.md) (every database a plugin),
  [docs/store.md](docs/store.md) (the database at the core).
- **Ask.** Start a [discussion](https://github.com/k8nstantin/schema-forge/discussions) with your question; there are no silly ones. Saying what confused you is a
  contribution too: it shows where the docs are thin.

## Three ways in

- **Build a wanted task.** The [Contribute page](https://k8nstantin.github.io/schema-forge/contribute.html) and the
  brief list what is wanted now. Nobody assigns it: open a new session on a fresh checkout of `main` and give your
  agent one line, the task file's path (`specs/tasks/SF-93.xml`). It builds, runs the gates and opens the pull
  request; you review it, then submit. Others may build the same task: the maintainer reviews the builds side by
  side, merges the best, and what their differences teach improves the method.
- **Bring something new**: an engine for a database you know, a feature, a fix. Open an issue or a discussion; you,
  your agent and the maintainer design it and write its task file; then it is built like any other.
- **Improve the method**: a lesson from your build, a rule that would have caught a mistake, a clearer step. Propose it
  in [Discussions](https://github.com/k8nstantin/schema-forge/discussions); it is decided in a design session.

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
- **Your coding agent is expected**, working by the method: one task file, one session, nothing decided that the file
  does not list, and no attribution of any kind. You are the author of what you submit: review it, and answer for
  every line.

## Licence

By contributing you agree that your work is licensed as SchemaForge is: MIT or Apache-2.0, at the user's choice.
