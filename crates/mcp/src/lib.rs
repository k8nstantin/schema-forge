//! The MCP the coding agent works through (served at `/mcp` by `schema-forge serve`). The agent reads the schemas and
//! the rules that hold on them, in plain words, and proposes rules; the system verifies each proposal and you
//! approve or reject it in the perspectives. The agent cannot approve, link or switch off a rule itself.

use std::fmt::Write as _;
use std::sync::Arc;

use rmcp::handler::server::{router::tool::ToolRouter, wrapper::Parameters};
use rmcp::model::{Implementation, ServerCapabilities, ServerConfig};
use rmcp::transport::streamable_http_server::session::local::LocalSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use rmcp::{ServerHandler, schemars, tool, tool_handler, tool_router};
use schema_forge_core::rules::review::{self, Proposed};
use schema_forge_core::rules::{self, Enforce, Scope};
use schema_forge_core::{Id, Schema, Target};
use schema_forge_store::Store;

/// The MCP service over `store`, for `axum::Router::nest_service("/mcp", …)`.
pub fn service(store: Arc<Store>) -> StreamableHttpService<Forge, LocalSessionManager> {
    StreamableHttpService::new(
        move || Ok(Forge::new(store.clone())),
        Arc::default(),
        StreamableHttpServerConfig::default(),
    )
}

/// The tools, one per session: a session keeps its turn on each schema.
#[derive(Clone)]
pub struct Forge {
    store: Arc<Store>,
    turns: Arc<std::sync::Mutex<std::collections::HashMap<String, u64>>>,
    tool_router: ToolRouter<Self>,
}

impl Forge {
    #[must_use]
    pub fn new(store: Arc<Store>) -> Self {
        Self { store, turns: Arc::default(), tool_router: Self::tool_router() }
    }

    /// The session's open turn on `schema`, opened when there is none.
    fn turn(&self, schema: &str) -> Result<u64, String> {
        let mine = self.turns.lock().map_err(|e| e.to_string())?.get(schema).copied();
        if let Some(n) = mine
            && self
                .store
                .turns(schema)
                .map_err(|e| e.to_string())?
                .iter()
                .any(|t| t.id == n && t.status == schema_forge_store::TurnStatus::Open)
        {
            return Ok(n);
        }
        let t =
            self.store.start_turn(schema, "changes made without a stated turn", "agent").map_err(|e| e.to_string())?;
        self.turns.lock().map_err(|e| e.to_string())?.insert(schema.to_string(), t.id);
        Ok(t.id)
    }
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct TurnArg {
    pub schema: String,
    /// What the person asked for, in a sentence: they review the turn's changes under it.
    pub summary: String,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct SchemaArg {
    /// The schema's name, as `schemas` lists it.
    pub schema: String,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct DescribeArg {
    pub schema: String,
    /// One table, by name: all of it. Without it, every table with its columns and types.
    #[serde(default)]
    pub table: Option<String>,
    /// Only the tables of this namespace (name or dotted path).
    #[serde(default)]
    pub namespace: Option<String>,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct RulesArg {
    pub schema: String,
    /// One table, by name: the rules on it, where each comes from, and what it breaks.
    #[serde(default)]
    pub table: Option<String>,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct CheckArg {
    pub schema: String,
    /// Only what breaks a hard rule.
    #[serde(default)]
    pub hard_only: bool,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct NewSchemaArg {
    /// Lowercase letters, digits, `-` and `_`, starting with a letter.
    pub name: String,
    /// `mysql`, `postgres` or `iceberg`.
    pub target: String,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct ChangeArg {
    pub schema: String,
    /// The operations, applied in order as one change: all of them, or none.
    pub operations: Vec<serde_json::Value>,
    /// Yes to destructive operations (drops, narrowed types, required columns): say it only when the person asked.
    #[serde(default)]
    pub confirm_destructive: bool,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct ProposeArg {
    pub schema: String,
    /// The rules you propose; each is verified and waits for the person's approval.
    pub proposals: Vec<ProposalArg>,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct ProposalArg {
    /// `new` (a rule written as a sentence), `link` (a rule of the catalog), or `off` (switch a rule off, with a
    /// reason).
    pub kind: String,
    /// For `new`: the sentence, as the `propose_rules` description shows.
    #[serde(default)]
    pub sentence: Option<serde_json::Value>,
    /// For `new`: the targets it checks (`mysql`, `postgres`, `iceberg`); none for every one.
    #[serde(default)]
    pub targets: Vec<String>,
    /// For `link` and `off`: the rule's id from `catalog`; `*` with `off` switches every rule off there.
    #[serde(default)]
    pub rule: Option<String>,
    /// For `off`: why.
    #[serde(default)]
    pub reason: Option<String>,
    /// Where: `schema`, `namespace:<name>`, `family:<namespace>/<family>`, `group:<name>` or `table:<name>`.
    pub at: String,
    /// `hard` (enforced: changes that break it are refused) or `soft` (highlighted only).
    pub enforce: String,
    /// Your evidence: why it fits, with numbers ("41 of 42 tables already have it").
    pub why: String,
}

fn target(t: &str) -> Result<Target, String> {
    match t {
        "mysql" => Ok(Target::Mysql),
        "postgres" | "postgresql" => Ok(Target::Postgres),
        "iceberg" => Ok(Target::Iceberg),
        _ => Err(format!("`{t}` is not a target: mysql, postgres or iceberg")),
    }
}

/// A level in words, by names.
fn level(model: &Schema, at: &Scope) -> String {
    let ns =
        |id: &Id| model.namespaces.iter().find(|n| &n.id == id).map_or(id.as_str(), |n| n.name.as_str()).to_string();
    match at {
        Scope::Global => "every schema".to_string(),
        Scope::Schema => "the whole schema".to_string(),
        Scope::Namespace { namespace } => format!("namespace {}", ns(namespace)),
        Scope::Family { namespace, family } => format!("family {family} of {}", ns(namespace)),
        Scope::Group { group } => format!("group {group}"),
        Scope::Table { table } => {
            format!(
                "table {}",
                model.tables.iter().find(|t| &t.id == table).map_or(table.as_str(), |t| t.name.as_str())
            )
        }
    }
}

fn type_label(t: &schema_forge_core::DataType) -> String {
    if t.is_verbatim() {
        return t.text.clone().unwrap_or_default();
    }
    let mut s = t.name.clone();
    if t.with_time_zone {
        s.push_str(" tz");
    }
    if let Some(l) = t.length {
        let _ = write!(s, "({l})");
    } else if let Some(p) = t.precision {
        let _ = write!(s, "({p}{})", t.scale.map(|x| format!(",{x}")).unwrap_or_default());
    }
    if let Some(of) = &t.of {
        let _ = write!(s, "<{}>", type_label(of));
    }
    if !t.fields.is_empty() {
        let _ = write!(s, "<{} fields>", t.fields.len());
    }
    s
}

const GRAMMAR: &str = r#"A new rule is a sentence, as JSON. Three forms:

1. Every column whose name matches must be something:
   {"columns": {"name": {"ends_with": "_at"}, "must": {"of_type": ["timestamptz"]}}}
   name: {"ends_with": …} | {"starts_with": …} | {"contains": …} | {"is": …}
   must: {"of_type": [types by the target's names]} | "required" | "described" | "snake_case"
2. Every table has a column:
   {"has_column": {"column": "loaded_at", "required": true, "types": ["string"]}}   (types optional)
3. Every table is partitioned by a transform of a column (Iceberg):
   {"partitioned_by": {"transform": "identity", "column": "region"}}

Reuse a rule of the catalog with kind "link" before writing a new one."#;

/// An operation as the agent writes it, with its types read from text for `target`.
/// Refuses a change that leaves a view's query naming what is no longer there, or reading something other than
/// what the view records: after a rename, the views that read it must be altered in the same change.
///
/// # Errors
/// The views whose queries no longer read what they record.
pub fn views_still_read(
    model: &schema_forge_core::Schema,
    ops: &[schema_forge_core::ops::Op],
    confirmed: bool,
) -> Result<(), String> {
    let mut after = model.clone();
    for op in ops {
        // A wrong operation is refused by the store, with its reason; here only the views are looked at.
        if schema_forge_core::ops::apply(&mut after, op, confirmed).is_err() {
            return Ok(());
        }
    }
    let reads_as_recorded = |s: &schema_forge_core::Schema, v: &schema_forge_core::View| {
        let names = schema_forge_dialects::view_relations(s.target, &v.definition)
            .map(|rs| rs.into_iter().map(|parts| parts.join(".")).collect::<Vec<_>>());
        names.and_then(|n| schema_forge_core::ops::resolve_reads(s, &n)).is_ok_and(|mut ids| {
            let mut want = v.reads.clone();
            ids.sort();
            want.sort();
            ids == want
        })
    };
    // Only what this change makes stale: a view already off before (an import that skipped a name) is not held
    // against it.
    let was_ok: Vec<&schema_forge_core::Id> =
        model.views.iter().filter(|v| reads_as_recorded(model, v)).map(|v| &v.id).collect();
    let stale: Vec<String> = after
        .views
        .iter()
        .filter(|v| {
            (was_ok.contains(&&v.id) || !model.views.iter().any(|o| o.id == v.id)) && !reads_as_recorded(&after, v)
        })
        .map(|v| format!("`{}`", v.name))
        .collect();
    if stale.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "views {} would read by names that are gone: alter them (alter_view) in the same change",
            stale.join(", ")
        ))
    }
}

pub fn operation(target: Target, mut v: serde_json::Value) -> Result<schema_forge_core::ops::Op, String> {
    let parse = |t: &mut serde_json::Value| -> Result<(), String> {
        if let Some(text) = t.as_str() {
            *t = serde_json::to_value(schema_forge_dialects::parse_type(target, text)?).map_err(|e| e.to_string())?;
        }
        Ok(())
    };
    if let Some(cols) = v.get_mut("columns").and_then(|c| c.as_array_mut()) {
        for c in cols.iter_mut().filter(|c| c.is_object()) {
            if let Some(t) = c.get_mut("type") {
                parse(t)?;
            }
        }
    }
    if let Some(t) = v.get_mut("column").and_then(|c| c.get_mut("type")) {
        parse(t)?;
    }
    if v.get("op").and_then(|o| o.as_str()) == Some("alter_column")
        && let Some(t) = v.get_mut("type")
    {
        parse(t)?;
    }
    // A view reads what its query names: found here, from the query, never taken from the caller.
    let op = v.get("op").and_then(|o| o.as_str()).unwrap_or("");
    if matches!(op, "add_view" | "alter_view")
        && let Some(definition) = v.get("definition").and_then(|d| d.as_str()).map(str::to_string)
    {
        let reads: Vec<String> = schema_forge_dialects::view_relations(target, &definition)?
            .into_iter()
            .map(|parts| parts.join("."))
            .collect();
        v["reads"] = serde_json::json!(reads);
    } else if let Some(o) = v.as_object_mut() {
        o.remove("reads");
    }
    serde_json::from_value(v).map_err(|e| format!("not an operation: {e}"))
}

#[tool_router]
impl Forge {
    #[tool(
        description = "Starts a turn on a schema: the changes you make for one request of the person, which they accept or reject together. Start one per request, with what they asked in a sentence; your `change` calls land in it."
    )]
    fn start_turn(&self, Parameters(a): Parameters<TurnArg>) -> Result<String, String> {
        let t = self.store.start_turn(&a.schema, &a.summary, "agent").map_err(|e| e.to_string())?;
        self.turns.lock().map_err(|e| e.to_string())?.insert(a.schema.clone(), t.id);
        Ok(format!("Turn {} started on {}: the person will accept or reject its changes together.", t.id, a.schema))
    }

    #[tool(
        description = "Makes an empty schema: a name and a type (mysql, postgres or iceberg). The person may link rules to it before you design."
    )]
    fn new_schema(&self, Parameters(a): Parameters<NewSchemaArg>) -> Result<String, String> {
        let info = self.store.create_schema(&a.name, target(&a.target)?).map_err(|e| e.to_string())?;
        let target = format!("{:?}", info.target).to_lowercase();
        Ok(format!("Made schema {} ({target}). Read its rules (`rules`) before you design it.", info.name))
    }

    #[tool(
        description = r#"Changes a schema's design: one or more operations, applied in order as one change, all or none. Each is checked against the model's own rules; then the whole against the schema's rules: a change that breaks a hard rule is refused, with the rule and the reason; what breaks a soft rule lands and is reported. Destructive operations need confirm_destructive. Every change shows live in the perspectives, and the person can undo it.

Operations, as JSON objects with "op". Tables are named `orders` or `namespace.orders`, columns `orders.total`; types as the target writes them (Iceberg: long, int, string, boolean, double, decimal(18,2), date, timestamptz, timestamp, binary, list<string>, map<string, long>, struct<a: int, b: string>; PostgreSQL: bigint, text, varchar(200), numeric(12,2), timestamptz, uuid, jsonb, text[]).
- add_namespace {name, parent?, comment?}
- add_table {namespace, name, comment?, columns: [{name, type, nullable?, default?, comment?}], primary_key?: [column names]} (on Iceberg the key becomes identifier fields)
- add_column {table, column: {name, type, …}, after?}; alter_column {column, type?, nullable?, default?, comment?}
- rename_table {table, name}; rename_column {column, name}; rename_namespace {namespace, name}; set_table_comment {table, comment}
- set_primary_key {table, columns}; set_identifier_fields {table, columns} (Iceberg)
- add_index {table, columns, unique?, name?}; drop_index {table, index} (MySQL, PostgreSQL)
- add_view {namespace, name, definition (one SELECT in the target's SQL: Spark SQL on Iceberg), columns?: [{name, type?, comment?}], comment?, materialized? (PostgreSQL)}; what it reads is found from the query
- alter_view {view, definition?, columns?, comment?} (on Iceberg a new version); rename_view {view, name}; add_view_dialect {view, dialect, definition} (Iceberg: the same query for another engine, e.g. trino)
- drop_view {view}: destructive; a table or view other views read cannot be dropped, and renaming one needs those views altered in the same change
- relate {from, columns, to, to_columns, name?}; unrelate {relationship}
- set_partition_spec {table, fields: [{column, transform}]}; set_property {table, key, value}; unset_property {table, key} (Iceberg)
- drop_table {table}; drop_column {column}; drop_namespace {namespace}: destructive."#
    )]
    fn change(&self, Parameters(a): Parameters<ChangeArg>) -> Result<String, String> {
        let e = |e: schema_forge_store::Error| e.to_string();
        let model = self.store.model(&a.schema).map_err(e)?;
        let target = model.target;
        let ops = a
            .operations
            .into_iter()
            .enumerate()
            .map(|(i, v)| operation(target, v).map_err(|m| format!("operation {}: {m}", i + 1)))
            .collect::<Result<Vec<_>, _>>()?;
        views_still_read(&model, &ops, a.confirm_destructive)?;
        let turn = self.turn(&a.schema)?;
        let changed = self.store.change_in(&a.schema, &ops, a.confirm_destructive, "agent", Some(turn)).map_err(e)?;
        let mut out = format!("Change #{} landed, in turn {turn}:\n", changed.operation.sequence);
        for s in &changed.summaries {
            let _ = writeln!(out, "- {s}");
        }
        if !changed.soft.is_empty() {
            let model = self.store.model(&a.schema).map_err(e)?;
            let _ = writeln!(out, "It breaks soft rules (highlighted, not refused):");
            for f in changed.soft.iter().take(20) {
                let t = model.tables.iter().find(|t| t.id == f.table).map_or(f.table.as_str(), |t| t.name.as_str());
                let _ = writeln!(out, "  {} @{t}: {}", f.rule, f.message);
            }
        }
        Ok(out)
    }

    #[tool(description = "The workspace's schemas: name and type (mysql, postgres, iceberg).")]
    fn schemas(&self) -> Result<String, String> {
        let list = self.store.schemas().map_err(|e| e.to_string())?;
        Ok(list.iter().map(|s| format!("{} ({:?})", s.name, s.target).to_lowercase()).collect::<Vec<_>>().join("\n"))
    }

    #[tool(
        description = "A schema's tables and columns with their types and whether they are required: one table whole, a namespace, or every table. Read this to learn the conventions a schema already follows."
    )]
    fn describe(&self, Parameters(a): Parameters<DescribeArg>) -> Result<String, String> {
        let model = self.store.model(&a.schema).map_err(|e| e.to_string())?;
        let set = self.store.rules(&a.schema).map_err(|e| e.to_string())?;
        let only_ns = match &a.namespace {
            Some(n) => match rules::parse_scope(&model, &set, &format!("namespace:{n}"))? {
                Scope::Namespace { namespace } => Some(namespace),
                _ => None,
            },
            None => None,
        };
        let mut out = String::new();
        for t in &model.tables {
            if a.table.as_deref().is_some_and(|n| n != t.name) || only_ns.as_ref().is_some_and(|n| n != &t.namespace) {
                continue;
            }
            let ns = model.namespaces.iter().find(|n| n.id == t.namespace).map_or("", |n| n.name.as_str());
            let _ =
                writeln!(out, "{ns}.{}{}", t.name, t.comment.as_deref().map(|c| format!(": {c}")).unwrap_or_default());
            for c in &t.columns {
                let _ = write!(
                    out,
                    "  {} {}{}",
                    c.name,
                    type_label(&c.data_type),
                    if c.nullable { "" } else { " required" }
                );
                if a.table.is_some()
                    && let Some(cm) = &c.comment
                {
                    let _ = write!(out, ": {cm}");
                }
                out.push('\n');
            }
            if let Some(ice) = &t.options.iceberg {
                let name = |id: &Id| {
                    t.columns.iter().find(|c| &c.id == id).map_or(id.as_str(), |c| c.name.as_str()).to_string()
                };
                if !ice.partition_spec.is_empty() {
                    let spec: Vec<String> =
                        ice.partition_spec.iter().map(|p| format!("{}({})", p.transform, name(&p.source))).collect();
                    let _ = writeln!(out, "  partitioned by {}", spec.join(", "));
                }
                if !ice.identifier_fields.is_empty() {
                    let ids: Vec<String> = ice.identifier_fields.iter().map(name).collect();
                    let _ = writeln!(out, "  identifier fields {}", ids.join(", "));
                }
            }
        }
        for v in &model.views {
            if a.table.as_deref().is_some_and(|n| n != v.name) || only_ns.as_ref().is_some_and(|n| n != &v.namespace) {
                continue;
            }
            let ns = model.namespaces.iter().find(|n| n.id == v.namespace).map_or("", |n| n.name.as_str());
            let reads: Vec<&str> = v
                .reads
                .iter()
                .filter_map(|r| {
                    model
                        .tables
                        .iter()
                        .find(|t| &t.id == r)
                        .map(|t| t.name.as_str())
                        .or_else(|| model.views.iter().find(|x| &x.id == r).map(|x| x.name.as_str()))
                })
                .collect();
            let _ = writeln!(
                out,
                "{ns}.{} (view, reads {}){}",
                v.name,
                reads.join(", "),
                v.comment.as_deref().map(|c| format!(": {c}")).unwrap_or_default()
            );
            if a.table.is_some() {
                let _ = writeln!(out, "  {}", v.definition.replace('\n', "\n  "));
            }
        }
        if out.is_empty() {
            return Err("no table or view matches".to_string());
        }
        Ok(out)
    }

    #[tool(
        description = "The rules that hold on a schema, in plain words: what is linked at which level (every schema, the schema, a namespace, a family, a group, a table), hard or soft, and the exceptions with their reasons. With a table: the rules on that table, where each comes from, and what it breaks. Read this before you design or change anything, and design within it. Hard rules are enforced: a change that breaks one is refused. Soft rules are highlighted."
    )]
    fn rules(&self, Parameters(a): Parameters<RulesArg>) -> Result<String, String> {
        let e = |e: schema_forge_store::Error| e.to_string();
        let model = self.store.model(&a.schema).map_err(e)?;
        let global = self.store.global_rules().map_err(e)?;
        let set = self.store.rules(&a.schema).map_err(e)?;
        let cat = self.store.catalog().map_err(e)?;
        let report = rules::check_with(&cat, &model, &global, &set);
        let title = |id: &str| {
            if id == rules::ALL {
                "every rule".to_string()
            } else {
                cat.rule(id).map_or_else(|| id.to_string(), |r| r.title.clone())
            }
        };
        let mut out = String::new();
        if let Some(name) = &a.table {
            let Scope::Table { table } = rules::parse_scope(&model, &set, &format!("table:{name}"))? else {
                return Err(format!("`{name}` is not a table"));
            };
            let eff = &report.tables[&table];
            if eff.applied.is_empty() {
                let _ = writeln!(out, "No rules hold on {name}.");
            }
            for ap in &eff.applied {
                let checks = cat.checks(&ap.rule);
                let hard = checks.iter().filter(|c| eff.hard(&cat, c)).count();
                let _ = writeln!(
                    out,
                    "- {} (@rule:{}), from {}{}; {hard} of its {} checks hard",
                    title(&ap.rule),
                    ap.rule,
                    level(&model, &ap.from),
                    if ap.locked { ", locked" } else { "" },
                    checks.len()
                );
            }
            for ex in &eff.excepted {
                let _ = writeln!(
                    out,
                    "- switched off: {} at {}, because {}",
                    title(&ex.rule),
                    level(&model, &ex.at),
                    ex.reason
                );
            }
            for f in report.findings.iter().filter(|f| f.table == table) {
                let _ = writeln!(out, "  breaks {} {}: {}", if f.hard { "hard" } else { "soft" }, f.rule, f.message);
            }
            return Ok(out);
        }
        if global.is_empty() && set.links.is_empty() {
            return Ok(format!(
                "No rules are linked to {}: design freely, or propose rules with propose_rules.",
                a.schema
            ));
        }
        for l in global.iter().chain(&set.links) {
            let how = if l.off {
                format!("switched off, because {}", l.reason.as_deref().unwrap_or(""))
            } else {
                let mut h = match l.enforce {
                    Some(Enforce::Hard) => "hard".to_string(),
                    Some(Enforce::Soft) => "soft".to_string(),
                    None => "each check as its default".to_string(),
                };
                if l.locked {
                    h.push_str(", locked");
                }
                h
            };
            let _ = writeln!(out, "- {} (@rule:{}) at {}: {how}", title(&l.rule), l.rule, level(&model, &l.at));
            if let Some(r) = cat.rule(&l.rule).filter(|r| !r.rules.is_empty()) {
                for c in cat.checks(&r.id) {
                    let _ = writeln!(out, "    {c}: {}", title(c));
                }
            }
        }
        for g in &set.groups {
            let names: Vec<&str> = g
                .tables
                .iter()
                .filter_map(|t| model.tables.iter().find(|m| &m.id == t))
                .map(|t| t.name.as_str())
                .collect();
            let _ = writeln!(out, "group {}: {}", g.name, names.join(", "));
        }
        let hard = report.findings.iter().filter(|f| f.hard).count();
        let _ = writeln!(out, "Now: {} findings, {hard} of them hard. `check` lists them.", report.findings.len());
        Ok(out)
    }

    #[tool(
        description = "What breaks the schema's rules now, one line each: hard or soft, the rule, the table and column, and what is wrong."
    )]
    fn check(&self, Parameters(a): Parameters<CheckArg>) -> Result<String, String> {
        let e = |e: schema_forge_store::Error| e.to_string();
        let model = self.store.model(&a.schema).map_err(e)?;
        let cat = self.store.catalog().map_err(e)?;
        let report = rules::check_with(
            &cat,
            &model,
            &self.store.global_rules().map_err(e)?,
            &self.store.rules(&a.schema).map_err(e)?,
        );
        let mut out = String::new();
        let mut n = 0;
        for f in report.findings.iter().filter(|f| f.hard || !a.hard_only) {
            n += 1;
            if n > 400 {
                continue;
            }
            let t = model.tables.iter().find(|t| t.id == f.table);
            let col = f.column.as_ref().and_then(|c| t.and_then(|t| t.columns.iter().find(|x| &x.id == c)));
            let _ = writeln!(
                out,
                "{} {} @{}{}: {}",
                if f.hard { "hard" } else { "soft" },
                f.rule,
                t.map_or("?", |t| t.name.as_str()),
                col.map(|c| format!(".{}", c.name)).unwrap_or_default(),
                f.message
            );
        }
        if n > 400 {
            let _ = writeln!(out, "… and {} more", n - 400);
        }
        Ok(if out.is_empty() { "Nothing breaks the rules.".to_string() } else { out })
    }

    #[tool(
        description = "Every rule there is, built in and the workspace's own: its id, lane (shared, mysql, postgres, iceberg, between), topic, whether it is hard by default, and the rules a pack is made of. Then the grammar new rules are written in."
    )]
    fn catalog(&self) -> Result<String, String> {
        let cat = self.store.catalog().map_err(|e| e.to_string())?;
        let mut out = String::new();
        for r in &cat.rules {
            let kind = match (r.rules.is_empty(), r.strength) {
                (false, _) => "pack",
                (true, rules::Strength::Must) => "hard by default",
                (true, rules::Strength::Should) => "soft by default",
            };
            let lane = format!("{:?}", r.lane).to_lowercase();
            let made = if r.rules.is_empty() { String::new() } else { format!(" made of {}", r.rules.join(", ")) };
            let _ = writeln!(out, "{}: {} [{lane}, {}, {kind}]{made}", r.id, r.title, r.topic);
        }
        out.push('\n');
        out.push_str(GRAMMAR);
        Ok(out)
    }

    #[tool(
        description = r#"Propose rules for a schema: new ones written as sentences, rules of the catalog to link, or rules to switch off with a reason. The system verifies each (written right, not a repeat, not contradicting a linked rule, and what it would break) and the person approves or rejects it in the Rules perspective. Nothing holds until it is approved; you cannot approve. Learn rules from what the schema already does (describe), with numbers as evidence.

A new rule is a sentence, as JSON. Three forms:
1. Columns whose name matches must be something: {"columns": {"name": {"ends_with": "_at"}, "must": {"of_type": ["timestamptz"]}}}; name is ends_with, starts_with, contains or is; must is {"of_type": [types]}, "required", "described" or "snake_case".
2. Every table has a column: {"has_column": {"column": "loaded_at", "required": true, "types": ["string"]}}.
3. Every table is partitioned (Iceberg): {"partitioned_by": {"transform": "identity", "column": "region"}}.
Reuse a catalog rule (kind link) before writing a new one."#
    )]
    fn propose_rules(&self, Parameters(a): Parameters<ProposeArg>) -> Result<String, String> {
        let e = |e: schema_forge_store::Error| e.to_string();
        let model = self.store.model(&a.schema).map_err(e)?;
        let set = self.store.rules(&a.schema).map_err(e)?;
        let mut items = Vec::new();
        for (i, p) in a.proposals.iter().enumerate() {
            let n = i + 1;
            let at = rules::parse_scope(&model, &set, &p.at).map_err(|m| format!("proposal {n}: {m}"))?;
            let enforce = match p.enforce.as_str() {
                "hard" => Enforce::Hard,
                "soft" => Enforce::Soft,
                other => return Err(format!("proposal {n}: enforce is hard or soft, not `{other}`")),
            };
            let rule = || p.rule.clone().ok_or(format!("proposal {n}: say which rule"));
            let what = match p.kind.as_str() {
                "new" => {
                    let sentence = p.sentence.clone().ok_or(format!("proposal {n}: a new rule needs its sentence"))?;
                    let sentence = serde_json::from_value(sentence)
                        .map_err(|m| format!("proposal {n}: the sentence is not written right ({m})"))?;
                    let targets = p.targets.iter().map(|t| target(t)).collect::<Result<Vec<_>, _>>()?;
                    Proposed::New { sentence, targets }
                }
                "link" => Proposed::Link { rule: rule()? },
                "off" => Proposed::Off {
                    rule: rule()?,
                    reason: p
                        .reason
                        .clone()
                        .filter(|r| !r.trim().is_empty())
                        .ok_or(format!("proposal {n}: say why"))?,
                },
                other => return Err(format!("proposal {n}: kind is new, link or off, not `{other}`")),
            };
            items.push((what, at, enforce, p.why.clone()));
        }
        let kept = self.store.propose(&a.schema, items, "agent").map_err(e)?;
        let verdicts = self.verdicts(&a.schema, &kept.iter().map(|p| p.id).collect::<Vec<_>>())?;
        Ok(format!(
            "{verdicts}\nThe person reviews them in the Rules perspective (Review). Nothing holds until approved."
        ))
    }

    #[tool(
        description = "The schema's proposals: what each says, its status (proposed, approved, rejected) and, while open, the system's verdict."
    )]
    fn proposals(&self, Parameters(a): Parameters<SchemaArg>) -> Result<String, String> {
        let all = self.store.proposals(&a.schema).map_err(|e| e.to_string())?;
        if all.is_empty() {
            return Ok("No proposals.".to_string());
        }
        self.verdicts(&a.schema, &all.iter().map(|p| p.id).collect::<Vec<_>>())
    }
}

impl Forge {
    /// Proposals `ids` with their status and, while open, the system's verdict.
    fn verdicts(&self, schema: &str, ids: &[u64]) -> Result<String, String> {
        let (model, all) = self.store.reviewed(schema).map_err(|e| e.to_string())?;
        let mut out = String::new();
        for r in all.iter().filter(|r| ids.contains(&r.proposal.id)) {
            let p = &r.proposal;
            let status = match (&r.verdict, p.status) {
                (Some(v), _) => format!("{:?}", v.state).to_lowercase(),
                (None, review::Status::Approved) => {
                    format!("approved{}", p.rule.as_deref().map(|r| format!(" as @rule:{r}")).unwrap_or_default())
                }
                (None, _) => "rejected".to_string(),
            };
            let how = if p.enforce == Enforce::Hard { "hard" } else { "soft" };
            let _ = writeln!(out, "#{} {} at {} ({how}): {status}", p.id, r.title, level(&model, &p.at));
            for n in r.verdict.iter().flat_map(|v| &v.notes) {
                let _ = writeln!(out, "  {}: {}", format!("{:?}", n.mark).to_lowercase(), n.text);
            }
        }
        Ok(out)
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Forge {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("schema-forge", env!("CARGO_PKG_VERSION")))
            .with_instructions(
            "Schema Forge: schemas designed with rules. Read `rules` for a schema before you design or change it, then \
             change it with `change`, within the rules: a change that breaks a hard rule is refused, with the rule and \
             the reason; soft rules are highlighted. Every change shows live and the person can undo it. You may propose \
             rules (propose_rules); the person approves them. You never approve, link or switch off a rule yourself, and \
             you confirm destructive operations only when the person asked for them.",
        )
    }
}
