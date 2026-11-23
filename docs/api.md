# The server's API

The contract between `schema-forge serve` (crates/serve) and the canvas (canvas/). Written before the code, and held
to it by tests: the routes the server answers are exactly the ones listed here (`crates/serve/tests/contract.rs`), and
every response the canvas reads is a Rust type whose TypeScript the canvas is generated from
(`canvas/src/api/types.ts`, which the check refuses when it is stale).

## What is the engine's, and what is shared

The server asks the registry for each schema's engine and never names a database. It sends the canvas **views**,
built from the model and the shared section layout (`schema_forge_engine::sections`), never an engine's raw section:

| The canvas gets | From |
|---|---|
| the engine's name, versions, kinds and their names, its word for a namespace, what it reads, whether it writes | the engine's declarations (`Engine`, `Read`, `Write`) |
| a connection form | the engine's declared fields (`Live::fields`): key, label, kind, choices, default, help, required |
| where a connection points | the engine's `Live::summary`, never built from field keys by the canvas |
| each test step and what it said | the engine's `Live::test` |
| an object's columns, keys, indexes, checks, partitions, query, routine, trigger, event | the shared layout's slots, read by the server |
| what belongs to one engine alone (its options) | key and value, as text, shown as they are: the canvas never reads one by name |
| an object's definition and the whole schema's SQL | the engine's `Write` |
| families, copies and links | the shape, computed by the server from the model alone |

**The canvas never names an engine, a field key, a kind id or an option name.** It shows what it is sent. The
architecture check holds that (`tools/architecture`), and every test of the server and the canvas runs on every engine
in the test registry, MySQL and Quill (`schema_forge_engines::for_tests`), which are unlike each other on purpose.

## Secrets

A secret is sent with one test or read (`secret`), used, and dropped. It is never written to the workspace, never
logged, never returned, never put in a URL. A profile sent with a value for a field the engine declares secret is
refused. The server answers only this machine: a request whose `Host` is not the loopback address, or whose `Origin`
is another site, is refused (403).

## Errors

Every failure is a status and `{ "error": "<a sentence>" }`: 400 when the request cannot be done as asked, 404 when
what it names is not there, 403 when it does not come from this machine.

## Routes

| Method | Path | Body | Answers |
|---|---|---|---|
| `GET` | `/api/engines` | | `Engine[]` |
| `GET` | `/api/workspace` | | `WorkspaceInfo` |
| `GET` | `/api/browse` | query `path` (default `~`) | `Listing` |
| `GET` | `/api/schemas` | | `SchemaSummary[]` |
| `POST` | `/api/schemas/import` | `ImportRequest` | `ReadResult` |
| `POST` | `/api/schemas/live` | `LiveReadRequest` | `ReadResult` |
| `GET` | `/api/schemas/{name}` | | `SchemaView` |
| `DELETE` | `/api/schemas/{name}` | | `Done` |
| `GET` | `/api/schemas/{name}/report` | | `ReadReport` |
| `GET` | `/api/schemas/{name}/definition/{object}` | | text: the object's definition, as its engine writes it |
| `GET` | `/api/schemas/{name}/sql` | | text: the whole schema, as its engine writes it |
| `GET` | `/api/connections` | | `ConnectionView[]` |
| `PUT` | `/api/connections/{name}` | `ConnectionRequest` | `Done` |
| `DELETE` | `/api/connections/{name}` | | `Done` |
| `POST` | `/api/connections/test` | `TestRequest` | `TestResult` |

Anything else under `/api/` is 404. Every other path is the canvas.

## The types

Field names are as sent; `?` marks one that may be absent. The Rust types are in `crates/serve/src/api.rs`.

**`Engine`**: `id`, `name`, `namespace_word { one, many }`, `versions [{ id, name }]`, `default_version`,
`kinds [{ id, name, table }]` (`table`: whether the perspectives draw it as a table, which is a kind that holds keys),
`reads?` (what it reads, in a phrase), `writes`, `live? { fields: Field[] }`.

**`Field`**: `key`, `label`, `kind` (`text` | `number` | `one_of` | `path` | `secret`), `choices`, `default?`,
`help`, `required`.

**`WorkspaceInfo`**: `folder` (with `~` for your home).

**`Listing`**: `path`, `parent?`, `entries [{ name, dir, size?, hidden }]`, folders first.

**`SchemaSummary`**: `name`, `engine`, `engine_name`, `version`, `version_name`, `namespace_word`, `counts [{ kind,
name, count }]` (by kind, in the engine's order), `columns`, `links`, `source?`, `read_at?`, `adds_up?`,
`not_understood`, `problems`, `error?` (when the schema's file cannot be read; then only `name` is certain).

**`Source`**: `{ kind: "file", path }` or `{ kind: "live", connection, summary, which }`.

**`ImportRequest`**: `path`, `name`, `engine?` (when the file does not say), `replace`.

**`LiveReadRequest`**: `connection`, `secret?`, `which` (namespace names; empty for what the connection reads),
`name`, `replace`.

**`ReadResult`**: `schema: SchemaSummary`, `report: ReadReport`.

**`ReadReport`**: `unit`, `read`, `modelled`, `kept [{ kind, count }]`, `data`, `machinery`, `not_understood [{ at,
start }]`, `adds_up`.

**`SchemaView`**: `summary: SchemaSummary`, `namespaces [{ id, name, path }]`, `objects: ObjectView[]`, `links:
LinkView[]`, `shape: Shape`, `kept [{ kind, text }]`, `problems [{ object?, message }]`.

**`ObjectView`**: `id`, `kind`, `kind_name`, `table`, `namespace`, `name`, `comment?`, `columns: ColumnView[]`,
`keys [{ what, name?, columns }]` (`what`: `primary`, `unique`, `identifier`), `indexes [{ name, unique, method?,
parts, condition?, options }]` (`parts`: each a column name or an expression, with its direction and options, as
text), `checks [{ name?, expression, options }]`, `partitioning? { strategy?, by, partitions [{ name, bounds }],
options }`, `query?`, `routine? { parameters [{ name, type, mode }], returns?, language?, deterministic?, security?,
body, options }`, `trigger? { timing, events, on, condition?, body, options }`, `event? { schedule, enabled,
preserve, body, options }`, `reads` (object ids), `read_by` (object ids), `triggers` (object ids), `options`.

**`ColumnView`**: `id`, `name`, `type`, `null`, `comment?`, `default?`, `identity`, `generated? { expression, stored
}`, `options`.

**`LinkView`**: `id`, `name?`, `from { object, columns }`, `to { object, columns }`, `enforced`, `on_delete?`,
`on_update?`, `options`.

**`Shape`**: `tables [{ table, family, copy_of?, stack? { series, label, count } }]`, `families [{ namespace, name,
tables, copies }]`, `links [{ from, column, to, declared, shared }]`.

**Options**, wherever they appear: `[{ key, value }]`, both text, in the order the engine stored them.

**`ConnectionView`**: `name`, `engine`, `engine_name`, `values` (by field key, never a secret), `summary` (the
engine's), `tested? { at, outcome }` (`passed` | `warning` | `failed`).

**`ConnectionRequest`**: `engine`, `values` (by field key; a field the engine does not declare, or one it declares
secret, is refused).

**`TestRequest`**: either `name` (a saved connection) or `engine` and `values` (one not saved), and `secret?`.

**`TestResult`**: `outcome` (`passed` | `warning` | `failed`), `steps [{ step, name, outcome, said }]` (`step`:
`reach` | `secure` | `sign_in` | `version` | `rights`; `name` as people read it).

**`Done`**: `{ done: "<what was done>" }`.
