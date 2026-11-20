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

/// The tools.
#[derive(Clone)]
pub struct Forge {
    store: Arc<Store>,
    tool_router: ToolRouter<Self>,
}

impl Forge {
    #[must_use]
    pub fn new(store: Arc<Store>) -> Self {
        Self { store, tool_router: Self::tool_router() }
    }
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

#[tool_router]
impl Forge {
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
        if out.is_empty() {
            return Err("no table matches".to_string());
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
        let e = |e: schema_forge_store::Error| e.to_string();
        let model = self.store.model(schema).map_err(e)?;
        let global = self.store.global_rules().map_err(e)?;
        let set = self.store.rules(schema).map_err(e)?;
        let custom = self.store.custom_rules().map_err(e)?;
        let cat = rules::catalog().with(&custom);
        let all = self.store.proposals(schema).map_err(e)?;
        let cx =
            review::Context { cat: &cat, custom: &custom, schema: &model, global: &global, set: &set, proposals: &all };
        let mut out = String::new();
        for p in all.iter().filter(|p| ids.contains(&p.id)) {
            let v = review::verify(&cx, p);
            let status = match p.status {
                review::Status::Proposed => format!("{:?}", v.state).to_lowercase(),
                review::Status::Approved => {
                    format!("approved{}", p.rule.as_deref().map(|r| format!(" as @rule:{r}")).unwrap_or_default())
                }
                review::Status::Rejected => "rejected".to_string(),
            };
            let how = if p.enforce == Enforce::Hard { "hard" } else { "soft" };
            let _ = writeln!(out, "#{} {} at {} ({how}): {status}", p.id, v.title, level(&model, &p.at));
            if p.status == review::Status::Proposed {
                for n in &v.notes {
                    let _ = writeln!(out, "  {}: {}", format!("{:?}", n.mark).to_lowercase(), n.text);
                }
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
            "Schema Forge: schemas designed with rules. Read `rules` for a schema before you design or change it, and stay \
             within them: hard rules are enforced, soft ones highlighted. You may propose rules (propose_rules); the person \
             approves them in the Rules perspective. You never approve, link or switch off a rule yourself.",
        )
    }
}
