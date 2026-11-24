# Perspectives

What you see, and where you can change it by hand: the perspectives are where you look, point and direct
while the agent builds, and where you edit a table or a view with the same operations the agent uses. They must make a schema of three tables and one of three thousand equally easy to read.

## Entering the app: Home

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ SchemaForge                                                       [ + New schema ]      │
├──────────────────────────────────────────────┬───────────────────────────────────────────┤
│ Working on                                   │ Standards                                 │
│  orders     MySQL · mysql, debezium, scd2    │  Type defaults: MySQL · PostgreSQL ·      │
│             CDC ──► lakehouse.orders         │                 Iceberg                   │
│             2 findings · agent idle          │  Packs: debezium · scd2 · star schema ·   │
│  ledger     PostgreSQL · billing standard    │         company naming · lakehouse        │
│             locked v7 · 3 changes since      │  Templates: billing standard · lakehouse  │
│                                              │                                           │
│ All schemas  (search, filter by type)        │ Pipelines                                 │
│  …                                           │  orders ──► lakehouse.orders (Iceberg)    │
└──────────────────────────────────────────────┴───────────────────────────────────────────┘
```

- **Working on:** the schemas you have open or touched lately, each with its type, its rule collection,
  its pipeline, its findings and whether the agent is at work on it; one click opens it.
- **All schemas:** every schema in the workspace, searchable, filterable by type.
- **Standards:** the rules that exist: each type's defaults, the packs, your templates; one click opens
  Standards.
- **Pipelines:** every CDC pipeline, source to target.

## Starting a schema: New schema

One short flow, the same whether you click through it or the agent does it through the MCP:

1. **Name** it: `orders`.
2. **Type:** MySQL, PostgreSQL or Iceberg.
3. **Rules,** a collection: the type's defaults are selected; add packs (`debezium`, `scd2`,
   `company naming`) or start from a template; or none. Each pack shows in a line what it brings.
4. **Where it goes** (optional): a CDC target, e.g. "captured by Debezium into Iceberg as
   `lakehouse.orders`", which creates the pipeline and the Iceberg schema with its own collection
   (Iceberg defaults, plus the packs you choose).
5. **Summary:** `orders · MySQL · mysql, debezium, scd2 · CDC ──► lakehouse.orders (Iceberg)`. Create.

Then the agent comes in: once the schema is defined, you prompt it ("design an order system; orders and
customers are SCD Type 2"), and it designs under that collection. You can also start from an imported dump
instead of an empty schema, at step 1.

## The shape of the app

The first canvas, one zoomable map of every card and line, was judged unusable on a real schema: jumpy, a
tangle of lines, columns cut off when zoomed. It was redesigned with the operator through mocks, screen by
screen, and rebuilt as separate perspectives, each a plain page that does one job.

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ SchemaForge  SCHEMA orders  Iceberg  [Tables│Categories│Table│Map]  pointing at @orders.total  Copy │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│                              the perspective                                             │
│                                                                                          │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ Activity: changes as they land                                                           │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Top:** the schema's name, large, under a `schema` caption, with its type; the perspectives, keys
  `1`–`4`; what you point at, as the reference the agent reads (`@orders.total`): `C` copies it,
  `Shift+C` copies it with what it is.
- **Hierarchy everywhere:** schema › namespace › family › table. Schema and namespace are set bigger than
  the tables and marked by caption and a namespace pill, so you always know which one you are in.
- **Where you are is in the address:** `#/<schema>/<perspective>/<table or family>`, so it survives a reload
  and can be sent.
- **Bottom, Activity:** every change as it lands; the open schema reloads with it.

## The shape of a schema

What the perspectives group and draw is computed by the engine (`schema_forge_core::shape`, served at
`/api/schemas/<name>/shape`), so the agent and the browser see the same thing:

- **Families** come from names: a `prefix__` (`billing__invoices`), else the first word after a prefix most of
  the namespace shares (`tbl_ShopLogins` → `Shop`), when at least four tables share it; the rest are
  `ungrouped`. A namespace of twelve tables or fewer is one family.
- **Copies** stack under one table: a series of dated tables (`tbl_ShipLog202203`…), or temporary names
  (`_old`, `_bak`, `_3`). They draw no lines of their own.
- **Links** are the declared relationships, then column names that name a table (`node_id`, `StoreKey`,
  `PromotionID` → `nodes`, `tbl_Stores`, `tbl_Promotions`), then an `_id` column whose description names a
  table.
- **Shared keys:** a table that more than max(25, 15% of the namespace) tables refer to is noted, not drawn.

## The perspectives

| Perspective | What it answers | Shows |
|---|---|---|
| **Tables** | what is here | every table under its namespace, searchable by table or column name, sortable by family, columns, nesting, partitioning, links |
| **Categories** | what belongs together | namespaces, then families as cards listing their tables and where the family links |
| **Table** | everything about one table | a picker by namespace; the table's link diagram; every column (type, null or not null, description); its SQL in its engine's dialect; its copies |
| **Map** | how the families fit | families in columns, left to right by who refers to whom, each line with its count; click a family for its link diagram |
| **Consistency** | where it disagrees with itself | every inconsistency and failing rule, grouped, each with the agent's suggested fix (next) |
| **Changes** | what changed since the last version | added, changed and removed objects; any two versions compared (later) |
| **History** | how it got here | versions and the agent's turns: the prompt, the operations, who locked what, when (later) |
| **Pipeline** | source and target side by side | for a CDC pipeline: each source table beside its Iceberg table, column by column (later) |
| **Custom** | what you choose | your own selection of tables, columns, grouping, colours; saved, shareable, makeable by the agent (later) |

## The link diagram

One drawing, used by the Table and the Map: the thing in the middle, what refers to it on the left, what it
refers to on the right, one curved line per link.

- **Table:** the table in the middle with its key and its joining columns, those in gold; each table on the
  left names the column it joins by, each line landing on the row it joins; a click on any table walks there,
  a click on a row points at that column.
- **Map, one family:** the family's tables in the middle (those that link across first, gold where they refer
  out); the families that refer to it left, the ones it refers to right; a click on a table opens it.
- **Map, the whole schema:** families as cards in columns; a line between neighbouring columns is a curve,
  a line that skips columns or runs back runs in its own lane under the cards, never through them; each line
  carries its count. Families with no links across are listed under it.
- Colour follows the family when there are six or fewer, else the namespace, from a palette checked for
  colour-blind separation; green and red are kept for passing and breaking rules.

## The cues

One visual language, the same everywhere: key icons (primary, unique, foreign, identifier field); solid and
dashed lines; crow's foot and ring; dashed and double cards; badges; a faint dot for nullable; red and amber
rule markers with the rule's name on hover; green, amber and faded red as changes land; a pulsing outline on
what the agent is working on; a lock on what is unchanged since the last version; area colours from the
whole-schema view down to the card. A legend is one key away.

## Directing the agent

You prompt the agent while you look, so pointing is effortless. Everything you see has a reference the agent
resolves through the MCP:

| What you point at | Reference |
|---|---|
| a schema, a pipeline (Home) | `@schema:orders`, `@pipeline:orders-lakehouse` |
| a table, a view | `@orders` (`@billing.orders` when the name is in more than one namespace) |
| a column | `@orders.total` |
| a key, an index, a relationship | `@orders.fk_orders_customers` |
| a partition series | `@orders.partitions` |
| an area, a tag | `@area:billing`, `@tag:scd2` |
| a rule pack, a rule, a rule setting | `@pack:debezium`, `@rule:scd2`, `@rule:debezium.bigint_unsigned_handling` |
| a pipeline mapping (source column to target column) | `@map:orders.total` |
| a finding | `@finding:14` (an inconsistency or a failing rule, numbered while it lasts) |
| a locked version, a change, an agent turn | `@v3`, `@change:42`, `@turn:12` |
| a perspective, as you see it now | `@perspective` (which one, what is in view, the zoom level) |
| the current selection | `@selection` |
| your pinned notes | `@notes` |

- **Copy** (`C`) the reference of anything you see, **copy with context** (`Shift+C`), or **drag** it into
  your terminal: schemas, tables, columns, relationships, partition series, areas, packs, rules and their
  settings, pipeline mappings, findings, versions, changes, the agent's turns, the perspective as you see
  it, your selection.
- **Pin notes** to anything; tell the agent to work through `@notes`; each is marked when done.
- **The selection is shared:** what you select is `@selection` to the agent.
- **Watching the agent:** each operation animates in where it lands; the perspective follows the agent's
  work if you let it ("follow"), or stays where you are and marks what changed off-screen.
- **Accept or reject** a turn's changes in Activity, whole or one by one; undo a turn.
- **Every finding and rule marker** has "copy as instruction" ("fix `@finding:14`").

## Standards, its own place

The rules have their own perspectives (docs/rules.md, "The Standards UI"):

- **Collections:** a schema's packs in order, with every overlap between packs shown.
- **Catalog:** every rule by category, its setting and severity, switchable in place.
- **Examples:** what each rule accepts and refuses, live as you change it.
- **Try:** a collection against a schema: what would pass and fail, before adopting it.
- **Compare:** two packs or templates side by side.
- **Type standards:** each kind of data and its type per engine, edited like a spreadsheet.
- **Patterns:** each pattern drawn as a small diagram of what it adds.

## Look and feel

- SuperX's purple theme, light and dark; quiet surfaces, colour kept for meaning (areas, cues).
- Keyboard first: every perspective, search and copy has a key; a command palette for the rest.
- Fast: a change from the agent appears in well under a second; nothing waits on the whole schema to
  redraw.
- Readable at a glance, detailed on demand: a list to find, a link diagram to see how it fits, the table
  whole when you open it.
- Accessible: cues never rely on colour alone (icons and line styles carry meaning too).

## What the technology must do

The choice of UI technology (an open decision) follows from this design. It must:

1. draw large diagrams smoothly (thousands of cards, only the visible part rendered) with zoom levels that
   change what is drawn;
2. lay out graphs automatically and stably (layered layout with groups);
3. update live from the store as each operation lands;
4. render any perspective to an image for the agent (`render`), exactly as you see it;
5. carry the theme, keyboard use and accessibility above;
6. run where the user is: in the browser from `schema-forge serve`, and later as a desktop app.

**The candidates against these:**

| | Browser, TypeScript (React Flow, ELK) | Browser, Rust (Leptos or Dioxus to WebAssembly) | Native Rust (egui, Iced, Slint) |
|---|---|---|---|
| 1. large diagrams, semantic zoom | mature, proven (React Flow) | to build ourselves (canvas or WebGL drawing) | to build ourselves; fast drawing |
| 2. automatic layout | ELK (layered, groups) ready | to port or bind a layout engine | to port or bind a layout engine |
| 3. live updates | yes | yes | yes |
| 4. render for the agent | headless browser screenshot | headless browser screenshot | render to an image in-process |
| 5. theme, keyboard, accessibility | mature (browser + Mantine) | browser's, components to build | weaker accessibility |
| 6. browser and desktop | browser now, desktop via Tauri | browser now, desktop via Tauri | desktop only |
| one language with the engine | no | yes | yes |

**Decided** (operator, 2026-11-20): **browser perspectives in TypeScript (React Flow, ELK)**, served by the
Rust engine, desktop later through Tauri. It is the only column where the hardest parts (large diagrams,
semantic zoom, stable layout) already exist and are proven, so the effort goes into the design itself. The
engine stays pure Rust; the perspectives are one well-bounded part that talks to it through the store's
live queries and a small API.

**Revised** (operator, 2026-11-20, after the first canvas was judged unusable): the perspectives stay in the
browser in TypeScript, but React Flow and ELK are gone. The redesign draws no zoomable map; its link
diagrams are small, laid out by rule (left, middle, right; columns by who refers to whom) and drawn as plain
SVG, so they need neither a graph library nor a layout engine.
