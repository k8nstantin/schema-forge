# Writing an engine

How to add a database to Schema Forge. An engine is a Rust crate that tells Schema Forge everything about one
database; nothing else in Schema Forge changes when you add one. The design behind it is
[engines.md](engines.md); this is the how.

This guide grows with the interface: every change to the interface updates it in the same pull request. Today it
covers what the interface has so far: identity, versions, types, reading, writing, queries, checks, the registry and
the conformance kit. The worked example is `example`, a made-up engine small enough to read in one sitting:
[`crates/engine/tests/example/mod.rs`](../crates/engine/tests/example/mod.rs).

## 1. Make the crate

An engine lives in `engines/<database>`, named `schema-forge-<database>`, and says what it is:

```toml
[package]
name = "schema-forge-yourdb"
version.workspace = true
edition.workspace = true

[package.metadata.schema-forge]
role = "engine"
database = "yourdb"

[dependencies]
schema-forge-model = { path = "../../crates/model" }
schema-forge-engine = { path = "../../crates/engine" }
```

If yours is the first engine in `engines/`, add `"engines/*"` to the workspace's `members` in the top `Cargo.toml`
(cargo refuses a member pattern that matches nothing, so the folder joins with its first crate).

The architecture check (`tools/architecture`, run by every `cargo test`) holds you to the design:

- an engine depends on the model, the interface and helper crates, **never on another engine**;
- **one crate per database**: its versions live inside it, never in a crate of their own;
- your database's name belongs in your crate; no shared crate may name it, not even inside an identifier
  (`readYourDb`) or a comment;
- your `database` id is lowercase letters, digits and `_`.

## 2. Say who it is, and its versions

```rust
impl Engine for YourDb {
    fn id(&self) -> &'static str { "yourdb" }          // as schemas name it: never changes
    fn name(&self) -> &'static str { "YourDB" }        // as people say it
    fn versions(&self) -> &[Version] { VERSIONS }      // oldest first
    fn types(&self) -> &dyn Types { self }
}
```

Every feature of your engine says the version it came in (`Availability::since("4")`) and, if one took it away,
the version that did. A schema is designed for one version and is offered exactly that version's features. When your
database releases a new version, add it to `versions()` and mark the features it brings; nothing else changes.

## 3. Its types

`Types` gives the palette its groups and types, and reads a type written as text:

- **`groups()`**: the palette's groups, in order (whole numbers, exact decimals, text, dates and times…).
- **`catalog()`**: every type, in palette order: its name as your database writes it (a family that takes parameters
  is written with letters, `decimal(P,S)`), its group, what it holds in a plain sentence, an **example** that is a real
  type a column could have (`decimal(18,2)`), and the versions that have it.
- **`parse(text, version)`**: reads a column's type and returns its family and its text as your database writes it.
  Reading the text it returns gives the same text again. It refuses with a `TypeError`: `NotAType` when the text is
  not one of your types, `NotInVersion` (with the version it came in) when it is one the schema's version does not
  have, so the canvas can say "comes in version 3" instead of "not a type".
- **Examples are written exactly as you write them**: `decimal(18,2)`, never `DECIMAL( 18 , 2 )`; the palette puts the
  example into a column as it is.

`engine.types_in(version)` gives the types a schema at that version may use, in palette order.

A column holds its type as your text; only your engine reads it.

## 4. Reading files

`Read` turns your database's files into a schema:

- **`reads()`**: what it reads, for people ("schema-only dumps").
- **`recognises(input)`**: whether an input is yours, by what it says (a header, a folder's layout), never by its
  name. When no engine or more than one recognises an input, the person is asked which engine it is for.
- **`read(input)`**: the schema, and a `Report` that accounts for everything read: `read = modelled + kept + data`.
  What the model does not describe is **kept exactly as written** (in your engine section), with **where it was**,
  and written back in its place; data is left out and counted. Spacing between units (blank lines) is not content;
  say what your unit is (`statements`, `non-blank lines`, `files`). Something not understood is kept and listed, never an error: an error is only
  for an input that cannot be read at all.

## 5. Writing, queries and checks

- **`Write`**: one object's definition, and the whole schema, as your SQL. What your reader keeps, your writer writes
  back.
- **`Queries`**: what a view's query reads, as name parts.
- **`Checks`**: what makes a schema wrong for your database at its version, beyond the model's own checks.

Each is optional: an engine without a writer simply cannot export yet.

## 6. Register it

Add one line to the registry crate:

```rust
Registry::new()
    .with(schema_forge_yourdb::YourDb)
```

## 7. Pass the conformance kit

Give your crate sample files (`tests/samples/`) and one test:

```rust
use schema_forge_engine::kit::{self, QuerySample, Sample, Samples};

#[test]
fn the_engine_conforms() {
    kit::assert_conforms(&YourDb, &Samples {
        files: &[
            Sample { path: Path::new("tests/samples/shop.sql"), written_back: true },
            Sample { path: Path::new("tests/samples/metadata"), written_back: false },
        ],
        queries: &[QuerySample { query: "select * from sales.orders", reads: &[&["sales", "orders"]] }],
    });
}
```

A sample is `written_back` when it is in the form your engine writes (its SQL): written and read again, it must give
the same schema, written the same way twice. A form you only read (table metadata, a catalog's export) is not.
Every part your engine has needs samples that exercise it: an engine that reads with no sample file, or reads queries
with no sample query, does not conform.

The kit checks your identity and versions; every type (its example reads back exactly as itself in the versions that
have it, and is refused as `NotInVersion` by the others); every sample (recognised, read with a report that adds up, a
sound schema of your engine at one of its versions, every column's type your own, every object with a definition,
and, when written back, the same schema written the same way); and every sample query. It names everything that does
not conform. A part your engine does not have is not checked.

The kit's own tests break the `example` engine on purpose, one way each, to prove it finds each mistake:
[`crates/engine/tests/interface.rs`](../crates/engine/tests/interface.rs).
