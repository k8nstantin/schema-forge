# Contributing to Schema Forge

Thank you for wanting to help. Schema Forge grows by plugins, so the most useful contributions are often a database
or an extension nobody has covered yet.

## Before you start

Read [docs/engines.md](docs/engines.md): every decision behind the design, and why. The short version: the process
(screens, rules machinery, the agent's MCP) is shared by every database; everything about a database belongs to its
**engine**, one crate per database; engines share nothing with each other but the engine interface.

## Ways to contribute

- **A database:** write an engine, following [docs/writing-an-engine.md](docs/writing-an-engine.md). It lives in
  `engines/<database>`, fills the shared section layout, declares its kinds of object and its options as data, maps
  its types to Apache Arrow, and passes the conformance kit.
- **An extension of a database** (PostGIS, pgvector, a company's own conventions): write an add-on for its engine.
- **A fix or an improvement:** open an issue first that says what is wrong and what you propose.

## How work is done

- One issue, one branch, one pull request, one concern. An engine is built whole in one pull request.
- Every pull request passes **`tools/check.sh`**, the one command CI runs too: `cargo fmt --all --check`,
  `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`, and, once the canvas is in, its
  types, its build and its browser tests on every engine. Nothing is done until it passes. The tests include the
  **architecture check** (`tools/architecture`): it fails the build when a crate depends the wrong way, a database is
  named outside its engine, or engines share code.
- **Shared code (the server, the command line, the canvas) never assumes an engine.** It shows what an engine
  declares, through docs/api.md, and names no database and no engine's word (a connection field, a kind, an option):
  the architecture check reads every engine's declarations and fails on any of them in shared code. Every test of
  shared code runs on every engine of the test registry (`schema_forge_engines::for_tests`): the shipped ones and
  Quill (`engines/quill`), a made-up database built unlike them, so an assumption about one fails on the other. What
  each engine is tested on is data (`crates/serve/tests/fixtures/engines.json`), never code.
- **The API is written down before it is built** (docs/api.md). The server answers exactly the routes it lists, and
  the canvas's TypeScript is generated from the server's types (`canvas/src/api/types.ts`), so the two never drift.
- **A flow is written as a browser test before its screen** (`canvas/e2e/`), on every engine; a flow still marked
  `fixme` is one the canvas does not do yet.
- New code follows the code around it: plain names, documentation in full sentences, no dead code, nothing hardcoded
  that should be data.
- Public data types are `#[non_exhaustive]` with constructors, so the interface grows without breaking anyone.

## Licence

By contributing you agree that your work is licensed as Schema Forge is: MIT or Apache-2.0, at the user's choice.
