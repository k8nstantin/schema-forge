# Schema Forge (`sf`)

**Build your database schema together with your coding agent, and watch it take shape.**

You prompt the agent. The agent works through Schema Forge's MCP. Every change appears at once on a rich,
live view that you both see. When the schema is right, export it as SQL for MySQL or PostgreSQL.

```
 you ──prompt──► coding agent ──MCP──► sf ──► live views (you see them, the agent can render them)
                                        │
                                        └──► schema.sql   (MySQL or PostgreSQL)
```

## Start

```
cd myproject
sf serve
```

`sf serve` starts Schema Forge, adds its MCP to the project for Claude Code, and opens the views in your
browser. Then you prompt Claude Code in the same folder: "design an order system; orders are SCD Type 2".

## What it does

- **Builds the schema with the agent.** The agent reads the schema and the rules, then changes it one
  operation at a time: add a table, a column, a relation, a view. Each operation is checked against the
  rules before it applies. You steer by prompt, or point at something in a view and say "this one".
- **Shows it, live, from several sides.** Every change lands in every view as it happens:

  | View | Shows |
  |---|---|
  | **Diagram** | tables and views as cards, with their relationships |
  | **List** | every table and view with its columns, types and constraints |
  | **Definition** | the SQL definition of what you selected, in your target database |
  | **Categories** | the schema grouped by area or tag |
  | **Custom** | the tables, columns and grouping you choose, saved with the project |

- **Keeps to the rules.** Built-in (naming, keys, indexed foreign keys), patterns such as SCD Type 2, and
  your own rules. The agent sees every rule, and is told plainly when an operation breaks one.
- **Treats views as objects.** Database views carry their definition and know what they read, so a change
  that would break a view is caught.
- **Exports SQL.** One file per version: the whole schema, or the migration from the last version.
- **Reads what you have.** Import a MySQL or PostgreSQL schema dump; nothing in it is lost.

## How it is built

- **One model, one owner.** `sf serve` holds the schema. The agent's operations (through the MCP) and
  your edits (in the views) go through one queue, are saved to `schema.json`, and appear in every view at
  once.
- **Plain files, in git.** `schema.json` (the draft), `versions/` (locked versions, never edited),
  `sf.toml` and `rules/` (the rules), `views/` (custom views), `export/` (the SQL).
- **Rust**, with the views in the browser (React, React Flow), in SuperX's purple theme.

| Crate | Job |
|---|---|
| `sf-core` | the schema model, operations, rules, versions |
| `sf-dialects` | reading and writing MySQL and PostgreSQL |
| `sf-mcp` | the MCP the agent works through |
| `sf` | the command: `sf serve`, `sf import`, `sf export` |

## Roadmap

1. Import a dump and see it in the diagram, list and definition views; export SQL.
2. Build with the agent: the MCP, the rules, every change live.
3. Categories and custom views; editing by hand.
4. Locked versions and migrations.
5. **Deploy:** apply a version to a destination database directly, or through the exported SQL file.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT), at your option.
Unless you state otherwise, any contribution you submit for inclusion is dual licensed as above, without any
additional terms or conditions.
