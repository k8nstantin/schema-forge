# Writing an engine

How to add a database to Schema Forge. An engine is a Rust crate that tells Schema Forge everything about one
database; nothing else in Schema Forge changes when you add one. The design behind it is
[engines.md](engines.md); this is the how.

This guide grows with the interface: every change to the interface updates it in the same pull request. Today it
covers what the interface has so far: identity, versions, types, reading, writing, queries, checks, the registry and
the conformance kit. The worked example is Quill, a made-up database whose engine is small enough to read in one
sitting: [`engines/quill/src/lib.rs`](../engines/quill/src/lib.rs). It is also the engine every app and canvas test
runs beside MySQL, built unlike MySQL on purpose, so shared code that names one engine's vocabulary fails there.

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
    fn namespace_word(&self) -> Noun { Noun::new("database", "databases") }  // what your people call a namespace
}
```

The canvas and the agent say your words: a namespace is a `database` in one engine and a `schema` in another, and the
shared code never decides which.

Every feature of your engine says the version it came in (`Availability::since("4")`) and, if one took it away,
the version that did. A schema is designed for one version and is offered exactly that version's features. When your
database releases a new version, add it to `versions()` and mark the features it brings; nothing else changes.

## 3. Its types

What you give the interface is made with its constructor, never by naming every field: `Version::new("3", "format 3")`,
`TypeGroup::new("whole", "Whole numbers")`, `TypeSpec::new("decimal(P,S)", "exact", "An exact number…",
"decimal(18,2)").since("2")`, `Parsed::new(…)`, `TypeError::not_in_version(…)`, `Report::new("statements")`,
`Unread::new(…)`, `Imported::new(…)`, and the model's `Namespace::new`, `Object::new`, `Column::new`, `Link::new`,
`Area::new`, with the rest set by field (`object.comment = Some(…)`). The section layout's parts are made with
`Default` and set by field (`let mut key = Key::default(); key.columns = …`). That is what lets the interface and the
model grow without breaking your engine: a field added later gets a default, and your code still builds. For the same
reason, match a `TypeError` with a wildcard arm.

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

`types_in(version)` (from the `Offered` trait, on any engine) gives the types a schema at that version may use, in
palette order. It is worked out from your catalog and versions, not something you write or can override, so it cannot
disagree with them. When `parse` refuses a type
as `NotInVersion`, `since` is exactly the version your catalog says it came in (or `None` when a version took it
away): that is what the canvas tells the person.

A column holds its type as your text; only your engine reads it.

## 4. Where your data goes: the section layout and your options

Everything your engine stores on a schema goes in the parts' engine sections, and every engine's sections follow one
layout, `schema_forge_engine::sections`: fill the slots your database has (`ObjectSection.keys`, `.checks`,
`.indexes`, `.partitioning`, `.order`, `.query`…; `ColumnSection.default`, `.identity`, `.generated`; `LinkSection`;
`SchemaSection.kept`, `.requires`, `.format`) and leave the rest out. Read a section with `sections::read`, write it
with `sections::write`. Do not invent slots: a slot the layout does not have is refused.

What is your database's alone goes in an element's `options`, and **you declare every option** your engine may hold,
as data, in `Engine::options()`:

```rust
const OPTIONS: &[OptionSpec] = &[
    OptionSpec::new(Part::Object, "fillfactor", OptionKind::Integer, "How full each page is filled, in percent")
        .for_kinds(&["table"]),
    OptionSpec::new(Part::Key, "nulls_not_distinct", OptionKind::Flag, "Nulls count as equal").since("15"),
];
```

That list is your engine's own schema over the shared layout: the kit refuses an option you do not declare, one of
the wrong kind, or one the schema's version does not have, and the canvas builds its option forms from it. If what you
need does not fit a slot or an option, that is a finding about the layout: propose it upstream, never store it
elsewhere.

Declare your **kinds of object** the same way, in `Engine::kinds()`, each with the slots it uses:

```rust
const KINDS: &[ObjectKind] = &[
    ObjectKind::new("table", "Table", &[Slot::Keys, Slot::Checks, Slot::Indexes]),
    ObjectKind::new("view", "View", &[Slot::Query]),
];
```

An object of a kind you do not declare, or a slot its kind does not use (a view with indexes, a table with a query),
is refused; the canvas shows your kinds by their names. Account for **every kind of object your database has**:
tables and views, and also its procedures and functions (`Slot::Routine`), triggers (`Slot::Trigger`), scheduled
events (`Slot::Event`), sequences and types. Keep as written only what belongs to the server rather than the schema
(accounts, roles, grants), counted by kind, and say why in your engine's plan.

When your engine changes how it stores its options, raise `Engine::format()` and `SchemaSection.format`, and read what
your earlier versions wrote. The layout itself has a version too (`sections::LAYOUT`): check a schema with
`sections::layout_of` before reading it, so a schema written by a newer Schema Forge is refused whole, never read
with something dropped.

## 5. Your types as Arrow's

Implement `Portable`: `arrow_type` gives each of your types as an Apache Arrow type, and `engine_type` gives your type
for an Arrow type, each saying how faithful it is: `Mapped::exact` when it comes back as the same type,
`Mapped::approximate` when a detail is not kept (say which), `Mapped::lost` when nothing holds it (say what is lost).
That mapping is how your engine meets every other engine and the DataFusion layer: compatibility, conversion,
planned views and lineage work for your engine through it, so every engine has one. The kit holds an exact mapping to
coming back as the same type, and every column type in your samples to mapping. Depend on `arrow-schema` only; never
on DataFusion or the rest of Arrow.

## 6. Reading files

`Read` turns your database's files into a schema:

- **`reads()`**: what it reads, for people ("schema-only dumps").
- **`recognises(input)`**: whether an input is yours, by what it says (a header, a folder's layout), never by its
  name. When no engine or more than one recognises an input, the person is asked which engine it is for.
- **`read(input)`**: the schema, and a `Report` that accounts for everything read:
  `read = modelled + kept + data + machinery`. What the model does not describe is **kept exactly as written** (in
  your engine section), with **where it was**, and written back in its place; data is left out and counted; so is what
  a dump's own format does around the schema (saving and restoring settings, dropping before making, placeholders).
  Spacing between units (blank lines) is not content; say what your unit is (`statements`, `non-blank lines`,
  `files`). Something not understood is kept and listed, never an error: an error is only for an input that cannot be
  read at all. A credential (a password in a `CREATE USER`) is never kept: keep the statement without it, or leave it
  out and count it.

What the first engine learned, which yours will meet too:

- The layout's types are non-exhaustive: make each from its default and set its fields (the MySQL engine's `with!`
  macro does it in one expression), so a field added to the layout later breaks nothing.
- Store options in the order of their keys, so a schema is the same file however its SQL ordered the clauses; and
  remove a key with `shift_remove`, which keeps the order of the rest.
- An object made again under the same name (a dump's placeholder view, `CREATE OR REPLACE`) keeps its id.
- Resolve references once everything is read: a dump writes a table before the tables its foreign keys name.
- Never let a value change the statement around it: write every string as your database writes one, and check that
  every value written outside quotes (an engine, a collation, a size) is one word, or refuse to write it.
- Refuse what is not your database's rather than misread it (a fork's dump, a mode in which strings mean something
  else), and refuse a live read that would come back with something missing because the account cannot see it.
- Prove the writer against the database itself: load what it writes into a real server, dump it again with the
  database's own tool, and read that dump as the same schema (`engines/mysql/tests/samples/shop/roundtrip.sh`).

## 7. Reading the live database

`Live` reads a schema from a running database (see [connections.md](connections.md)):

- **`fields()`**: what a connection needs, as data (`Field::new(key, label, kind, help)`, `.required()`,
  `.default(…)`), at most one of them the secret. The Connections page and the agent's tools are built from them.
- **`summary(profile)`**: where a connection points, in a line people recognise (`reader@db.internal:3306 · sales`),
  never the secret, whatever the profile holds; the Connections page lists connections by it. The default lists the
  values of the fields that are not secret; the kit checks it never shows the secret.
- **`test(profile, secret)`**: the five steps, in order, each passed, warned, failed or skipped with what happened:
  reach, secure, sign in, version, rights. Stop at the first that fails and skip the rest; a warning (TLS not
  checked, an account that can change things) lets the rest run.
- **`read(profile, secret, which)`**: send only statements that read, and read what the database says through the
  same reader as its files, so a schema read live and one read from a dump of the same database are the same model.

The secret comes as a `Secret`, which never prints; never log it, never put it in an error, never store it. Test the
live part against the real database in containers, each version you support (`engines/mysql/tests/live.rs`).

## 8. Writing, queries and checks

- **`Write`**: one object's definition, and the whole schema, as your SQL. What your reader keeps, your writer writes
  back. Writing returns an error rather than drop anything: a section that does not read is an error, never an empty
  one.
- **`Queries`**: what a view's query reads, as name parts.
- **`Checks`**: what makes a schema wrong for your database at its version, beyond the model's own checks.

Each is optional: an engine without a writer simply cannot export yet.

## 9. Register it

Add one line to the registry crate:

```rust
Registry::new()
    .with(schema_forge_yourdb::YourDb)
```

## 10. Pass the conformance kit

Give your crate sample files (`tests/samples/`) and one test:

```rust
use schema_forge_engine::kit::{self, QuerySample, Sample, Samples};

#[test]
fn the_engine_conforms() {
    let files = [
        Sample::written_back(Path::new("tests/samples/shop.sql")),
        Sample::read_only(Path::new("tests/samples/metadata")),
    ];
    let queries = [QuerySample::new("select * from sales.orders", &[&["sales", "orders"]])];
    kit::assert_conforms(&YourDb, &Samples::new(&files, &queries));
}
```

A `written_back` sample is in the form your engine writes, exactly as it writes it: read and written again, it must
come back as **the same text**, line for line (blank lines aside), and read back to the same schema. That is how the
kit knows kept text goes back in its place. A form you only read (table metadata, a dump made by another tool) is
`read_only`. Every part your engine has needs samples that exercise it: reading needs a sample file, writing a
written-back sample when it also reads, reading queries a sample query. An engine that writes but does not read is
checked on its identity, versions and types until the interface gives it schemas to write.

The kit checks your identity and versions; every type (its example reads back exactly as itself in the versions that
have it, and is refused as `NotInVersion` by the others); every sample (recognised, read with a report that adds up, a
sound schema of your engine at one of its versions, every section in the layout and every id it names in the schema,
every option declared, every column's type your own, every object with a definition,
and, when written back, the same schema written the same way); and every sample query. It names everything that does
not conform. A part your engine does not have is not checked.

The kit's own tests break Quill on purpose, one way each, to prove it finds each mistake:
[`engines/quill/tests/kit.rs`](../engines/quill/tests/kit.rs).

## 11. Let people add onto your engine

Give your engine an add-on trait, so people extend it without forking it: a database extension's types, statements,
kept statements and later rules, each from an add-on crate registered with one line (`YourDb::new().with(Extra)`).
Build your engine's tables (types, statement handlers, kept kinds) from your built-ins and its add-ons, never as fixed
lists. Write the extensions you ship support for as add-ons themselves, using only what your crate makes public: they
are your add-on authors' examples. The MySQL engine's `AddOn` trait and its test of a compatible system's types
(`engines/mysql/tests/addon.rs`) are the worked example; the PostgreSQL engine's add-ons (PostGIS, pgvector, citext,
hstore) will be the next.
