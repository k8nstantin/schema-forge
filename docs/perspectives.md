# Perspectives

What you see. You never edit the schema: the perspectives are where you look, point and direct, while the
agent builds. They must make a schema of three tables and one of three thousand equally easy to read.

## Entering the app: Home

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Schema Forge                                                       [ + New schema ]      │
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

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Schema Forge   [workspace ▾]  orders · Iceberg · lakehouse rules        ● agent working   │
├────────┬─────────────────────────────────────────────────────────────┬────────────────────┤
│        │                                                             │                    │
│ Schemas│                 the perspective                             │  Inspector         │
│ ────── │                 (Diagram, List, Definition, …)              │  what is selected: │
│ orders │                                                             │  its detail, rules,│
│ ledger │                                                             │  history, SQL,     │
│        │                                                             │  references        │
│ Pipe-  │                                                             │                    │
│ lines  │                                                             │                    │
│        │                                                             │                    │
│Standards                                                             │                    │
├────────┴─────────────────────────────────────────────────────────────┴────────────────────┤
│ Activity: the agent's turns as they happen · findings · changes          @selection: orders │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Left:** the workspace: schemas, pipelines, and **Standards** (its own place, see below).
- **Centre:** one perspective at a time, switched by tabs or keys `1`–`9`; any perspective can be split
  beside another (Diagram beside Definition, the source beside the target of a pipeline).
- **Right, the Inspector:** everything about what is selected, the same in every perspective.
- **Bottom, Activity:** the agent's turns, operation by operation, as they land; findings; the current
  selection's reference, one click to copy.
- **Top:** the schema, its type, its rule collection, and whether the agent is working.

## The perspectives

| Perspective | What it answers | Shows |
|---|---|---|
| **Diagram** | how it fits together | tables and views as cards, relationships, areas; zoom from the whole schema into one table |
| **List** | what exactly is defined | every table and view: columns, types, nullability, defaults, constraints; sortable, filterable, grouped |
| **Definition** | what the database will be told | the SQL of what is selected, in the target's dialect, as it will be exported |
| **Categories** | what belongs together | the schema by area and by tag, with each group's rule status |
| **Dependencies** | what relies on what | views and what they read; relationships as a graph; "what breaks if this changes" for anything selected |
| **Consistency** | where it disagrees with itself | every inconsistency and failing rule, grouped, each with the agent's suggested fix |
| **Changes** | what changed since the last version | added, changed and removed objects, on the diagram and as a list; any two versions compared |
| **History** | how it got here | versions and the agent's turns: the prompt, the operations, who locked what, when |
| **Pipeline** | source and target side by side | for a CDC pipeline: each source table beside its Iceberg table, column by column, with the rule that decided each mapping |
| **Custom** | what you choose | your own selection of tables, columns, grouping, colours; saved, shareable, makeable by the agent |

## The diagram, in depth

**Zoom changes what is drawn,** not only its size:

| Level | Drawn |
|---|---|
| Whole schema | areas as coloured regions, tables as named blocks, how areas connect (one line per pair of areas, its weight the number of relationships) |
| Area | tables with their keys; relationships between them |
| Table | the full card: every column, type, constraint, index, badge and rule marker |
| Focus | one table centred, its neighbours around it, everything else faded; the Inspector opens on it |

**Cards:** name, area colour band, badges (`scd2`, `fact`, partitioned, sorted), columns with key icons,
types and nullability; a view's card dashed, a materialized view's doubled; a partition series one row
("1,096 daily partitions").

**Lines:** crow's foot and ring for cardinality; solid for enforced, dashed for logical; labelled with the
columns they join when zoomed in; routed around cards.

**Layout:** automatic (layered, areas kept together) for an imported or agent-built schema; stable as the
schema grows, so a new table does not throw everything else around; positions remembered per schema.

**Large schemas:** areas fold; search jumps and focuses; a minimap; only what is on screen is drawn, so
thousands of tables stay smooth.

## The cues

One visual language, the same everywhere: key icons (primary, unique, foreign, identifier field); solid and
dashed lines; crow's foot and ring; dashed and double cards; badges; a faint dot for nullable; red and amber
rule markers with the rule's name on hover; green, amber and faded red as changes land; a pulsing outline on
what the agent is working on; a lock on what is unchanged since the last version; area colours from the
whole-schema view down to the card. A legend is one key away.

## Directing the agent

- **Copy a reference** of anything with one key (`C`) or click: `@orders`, `@orders.total`,
  `@rule:scd2`, `@finding:14`, `@v3`, `@change:42`; several selected copy together. References in the
  agent's replies (in Activity) are clickable.
- **The selection is shared:** what you select is `@selection` to the agent.
- **Watching the agent:** each operation animates in where it lands; the perspective follows the agent's
  work if you let it (a "follow" toggle), or stays where you are and marks what changed off-screen.
- **Accept or reject** a turn's changes in Activity, whole or one by one; undo a turn.
- **Ask about anything:** every finding and rule marker has "copy as instruction" ("fix `@finding:14`").

## Standards, its own place

The rules have their own perspectives (docs/rules.md, "The Standards UI"):

- **Collections:** a schema's packs in order, with every overlap between packs shown.
- **Catalog:** every rule by category, its setting and severity, switchable in place.
- **Examples:** what each rule accepts and refuses, live as you change it.
- **Try:** a collection against a schema: what would pass and fail, before adopting it.
- **Compare:** two packs or templates side by side.
- **Type standards:** each kind of data and its type per target, edited like a spreadsheet.
- **Patterns:** each pattern drawn as a small diagram of what it adds.

## Look and feel

- SuperX's purple theme, light and dark; quiet surfaces, colour kept for meaning (areas, cues).
- Keyboard first: every perspective, zoom level, search and copy has a key; a command palette for the rest.
- Fast: a change from the agent appears in well under a second; nothing waits on the whole schema to
  redraw.
- Readable at a glance, detailed on demand: the Inspector holds detail so cards stay calm.
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
