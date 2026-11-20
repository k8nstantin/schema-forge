# Market scan (2026-11-20)

What exists near Schema Forge, from a web scan on 2026-11-20. Feature claims come from each project's own
pages and listings; nothing here was installed or tested.

## MCP plus ER diagrams: the direct neighbours

| Tool | What it is | Rules / standards | Iceberg, CDC | Licence |
|---|---|---|---|---|
| [drawDB + MCP](https://github.com/anatoly-lab/drawdb-mcp) | a fork of drawDB whose backend holds the diagram; MCP tools (export SQL/DBML, import DBML, import/export the diagram); a connected editor stays in sync, and edits in the editor go back | none mentioned | no | AGPL-3.0 |
| [drawDB](https://www.drawdb.app/) official MCP | read-only access to diagrams | none | no | AGPL-3.0 (drawDB) |
| [SchemaSketch](https://schemasketch.dev/) ([post](https://dev.to/schemasketch/your-ai-agent-can-now-design-edit-and-export-database-schemas-with-mcp-27f4)) | hosted; about 15 MCP tools to create, update and export diagrams; imports SQL, Mermaid, PlantUML | none mentioned | no | hosted service |
| [ER Flow](https://erflow.io/en) | visual modeler with an MCP server for Claude Code, Cursor, Windsurf; generates migrations | none mentioned | no | commercial |
| [Sqemo](https://glama.ai/mcp/servers/sqemo/sqemo-mcp) | the closest: 36 MCP tools to model, lint and export; names derived from a team word list and naming rules; domains define types; lint, diff, migration scripts, drift against PostgreSQL and MySQL | naming rules, word lists, domains | no | MIT server, commercial cloud and Pro tools; listed as inactive |

## AI schema design, with its own agent

- [Liam](https://github.com/liam-hq/liam) (Apache-2.0, about 4.9k stars): ER diagrams from existing
  schemas, and an AI design system of its own agents (requirements, schema design, QA) built on LangGraph,
  storing sessions in Supabase ([DeepWiki](https://deepwiki.com/liam-hq/liam)). Its agent, not yours.
- [ChartDB](https://sql-designer.com/blog/best-free-erd-tools): mostly documents existing schemas, with AI
  explanations.
- drawDB Pro, [DrawSQL](https://drawsql.app/): AI assistants inside the diagram tool.
- Text-to-ER generators ([Miro](https://miro.com/ai/erd-diagram-ai/),
  [Cloudairy](https://cloudairy.com/ai/ai-er-diagram-generator),
  [MockFlow](https://mockflow.com/ai/database-diagram-generator/)): a description in, a diagram out.

## Standards in classic modelers

Enterprise modelers enforce naming standards: [Oracle SQL Developer Data
Modeler](https://www.oracle.com/technetwork/developer-tools/datamodeler/datamodelernamingstandards-167685.pdf)
(naming patterns and design rules), [ER/Studio](https://docwiki.embarcadero.com/ERStudioDA/211/en/Enforcing_Naming_Standards_Using_Naming_Standards_Templates)
(naming standards templates). They are built for people editing by hand, not for agents. A
[Quest post](https://blog.quest.com/the-90-second-data-model-why-ai-generated-data-models-arent-a-modeling-practice/)
makes the same point we do: AI that suggests a convention without enforcing it is not modelling.

Teams also write conventions as a markdown file for their agent
([example](https://claudecodeguides.com/claude-md-for-database-conventions-and-patterns/)): guidance the
agent may follow, nothing that refuses a bad change.

## MySQL to Iceberg through CDC

No tool was found that designs Iceberg tables from a MySQL schema under standards. What exists runs the
pipeline and creates or evolves tables automatically:
[Estuary](https://estuary.dev/blog/mysql-to-apache-iceberg/),
[BladePipe](https://dev.to/bladepipe/how-to-load-data-from-mysql-to-iceberg-in-real-time-2f),
[Snowflake Openflow](https://docs.snowflake.com/en/user-guide/data-integration/openflow/connectors/mysql/iceberg),
[Cloudera](https://docs.cloudera.com/dataflow/cloud/readyflow-overview-mysqlcdc-iceberg/topics/cdf-readyflow-mysqlcdc-iceberg.html),
[Iceberg Kafka Connect on MSK](https://aws.amazon.com/blogs/big-data/use-amazon-msk-connect-and-iceberg-kafka-connect-to-build-a-real-time-data-lake),
[Debezium Server Iceberg](https://memiiso.github.io/debezium-server-iceberg/migration), and a published
[MySQL-to-Iceberg type table](https://docs.amazonaws.cn/en_us/firehose/latest/dev/database-as-source-supported-datatypes.html)
for Firehose. None of them shows the source's inconsistencies first, or lets you decide the target design
before data flows.

## Where Schema Forge stands apart

1. **Your agent, any agent.** It works with any coding agent that speaks MCP; Claude Code first. The MCP
   is the enforcer, not a convenience: every change goes through it and is checked.
2. **You direct, and can edit by hand.** The user sees, points and instructs, with references to everything,
   or makes the change in the perspectives, under the same rules as the agent.
3. **Standards by type:** type standards, naming, keys, patterns such as SCD Type 2, the Debezium pack;
   enforced on every operation, not suggested.
4. **Inconsistencies surfaced** across the whole schema, before they become data problems.
5. **Iceberg first-class**, and **CDC designed**: MySQL to Iceberg through Debezium, every column decided
   by rule, the connector's settings written to match.
6. **Local and open source** (MIT or Apache-2.0).

## What to watch

drawDB + MCP and Sqemo show the idea of an agent editing an ER model through MCP is already out there.
Schema Forge's difference has to stay where the list above puts it: enforced standards, CDC and Iceberg,
the many perspectives, and the agent as the only editor.
