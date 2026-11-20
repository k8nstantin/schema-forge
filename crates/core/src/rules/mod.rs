//! Rules (docs/rules.md): checks, and rules made of rules, linked at any level of the schema's hierarchy. A rule
//! linked at a level applies to everything under it, the nearest link wins, an exception switches a rule (or one
//! rule inside it) off below with a reason, and a locked rule cannot be switched off below where it is linked.

mod catalog;
mod checks;
pub mod compat;

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

pub use catalog::{Catalog, Goal, Lane, Rule, Strength, catalog};

use crate::{Id, Schema, Table};

/// The rule an exception names to switch every rule off: rules are optional, for a whole schema, a group, any level.
/// It holds over locks, since it is the choice not to use rules there at all; a link lower down still applies.
pub const ALL: &str = "*";

/// A level of the hierarchy a rule is linked at.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "level", rename_all = "snake_case", deny_unknown_fields)]
pub enum Scope {
    /// Every schema of the workspace.
    Global,
    /// The whole schema.
    Schema,
    /// A namespace, and the namespaces inside it.
    Namespace {
        namespace: Id,
    },
    /// A family of a namespace (perspectives' families: `node__`, `ungrouped`).
    Family {
        namespace: Id,
        family: String,
    },
    /// A group of tables you made.
    Group {
        group: String,
    },
    Table {
        table: Id,
    },
}

/// A rule linked at a level, or switched off there.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Link {
    pub rule: String,
    pub at: Scope,
    /// An exception: the rule, or a rule inside it, is switched off here and below.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub off: bool,
    /// Cannot be switched off below where it is linked.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub locked: bool,
    /// Why: required for an exception.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Tables grouped by hand, across namespaces and families, to link rules to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Group {
    pub name: String,
    pub tables: Vec<Id>,
}

/// A schema's rules: its links and its groups. The workspace's global links are kept apart and passed beside.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuleSet {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub links: Vec<Link>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub groups: Vec<Group>,
}

/// A rule reaching a table, and the level it was linked at.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Applied {
    pub rule: String,
    pub from: Scope,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub locked: bool,
}

/// A rule switched off for a table, where, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Excepted {
    pub rule: String,
    pub at: Scope,
    pub reason: String,
}

/// The rules on one table: what reaches it and what is switched off.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct Effective {
    pub applied: Vec<Applied>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub excepted: Vec<Excepted>,
}

/// One thing that breaks a rule.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Finding {
    /// The check that found it.
    pub rule: String,
    pub table: Id,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<Id>,
    pub message: String,
}

/// How a rule (a check, or a pack counting its checks) did: what it looked at, and how many broke it.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct Tally {
    pub checked: usize,
    pub breaks: usize,
}

/// A schema checked against its rules.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct Report {
    /// Every rule that reached a table, with its tally.
    pub tallies: BTreeMap<String, Tally>,
    pub findings: Vec<Finding>,
    /// The rules on each table.
    pub tables: BTreeMap<Id, Effective>,
    /// Links that do not hold (a rule or a level that is not there).
    pub problems: Vec<String>,
}

/// The levels above `table`, widest first: global, schema, its namespaces from the outermost, its family, the
/// groups it is in, itself.
fn chain(schema: &Schema, families: &HashMap<&Id, &str>, groups: &[Group], table: &Table) -> Vec<Scope> {
    let mut out = vec![Scope::Global, Scope::Schema];
    let mut namespaces = Vec::new();
    let mut at = Some(&table.namespace);
    while let Some(id) = at {
        namespaces.push(Scope::Namespace { namespace: id.clone() });
        at = schema.namespaces.iter().find(|n| &n.id == id).and_then(|n| n.parent.as_ref());
        if namespaces.len() > schema.namespaces.len() {
            break;
        }
    }
    out.extend(namespaces.into_iter().rev());
    if let Some(f) = families.get(&table.id) {
        out.push(Scope::Family { namespace: table.namespace.clone(), family: (*f).to_string() });
    }
    let mut mine: Vec<&Group> = groups.iter().filter(|g| g.tables.contains(&table.id)).collect();
    mine.sort_by(|a, b| a.name.cmp(&b.name));
    out.extend(mine.into_iter().map(|g| Scope::Group { group: g.name.clone() }));
    out.push(Scope::Table { table: table.id.clone() });
    out
}

/// The rules on `table`: walk its chain, widest first; a link adds a rule, an exception switches one off.
fn resolve(cat: &Catalog, chain: &[Scope], links: &[&Link]) -> Effective {
    let mut applied: Vec<Applied> = Vec::new();
    let mut excepted: Vec<Excepted> = Vec::new();
    for step in chain {
        for l in links.iter().filter(|l| &l.at == step && !l.off) {
            // Linked again lower down: the nearest link wins, unless the one above is locked.
            if applied.iter().any(|a| a.rule == l.rule && a.locked) {
                continue;
            }
            applied.retain(|a| a.rule != l.rule);
            excepted.retain(|e| !cat.contains(&l.rule, &e.rule));
            applied.push(Applied { rule: l.rule.clone(), from: step.clone(), locked: l.locked });
        }
        for l in links.iter().filter(|l| &l.at == step && l.off) {
            if l.rule == ALL {
                applied.clear();
                excepted = vec![Excepted {
                    rule: ALL.to_string(),
                    at: step.clone(),
                    reason: l.reason.clone().unwrap_or_default(),
                }];
                continue;
            }
            let holding: Vec<&Applied> = applied.iter().filter(|a| cat.contains(&a.rule, &l.rule)).collect();
            if holding.is_empty() || holding.iter().any(|a| a.locked) {
                continue;
            }
            if applied.iter().any(|a| a.rule == l.rule) {
                applied.retain(|a| a.rule != l.rule);
            }
            excepted.push(Excepted {
                rule: l.rule.clone(),
                at: step.clone(),
                reason: l.reason.clone().unwrap_or_default(),
            });
        }
    }
    Effective { applied, excepted }
}

impl Effective {
    /// The checks that run on the table: those of every rule that reaches it, less those switched off. An
    /// exception switches off only what it is part of: a pack linked on its own keeps its checks.
    #[must_use]
    pub fn checks<'a>(&self, cat: &'a Catalog) -> Vec<&'a str> {
        let mut out: Vec<&str> = Vec::new();
        for a in &self.applied {
            for c in cat.checks(&a.rule) {
                let off = self.excepted.iter().any(|e| cat.contains(&a.rule, &e.rule) && cat.contains(&e.rule, c));
                if !off && !out.contains(&c) {
                    out.push(c);
                }
            }
        }
        out
    }
}

/// The family each table is in, by the schema's shape.
fn families(schema: &Schema) -> HashMap<Id, String> {
    crate::shape(schema).tables.into_iter().map(|t| (t.table, t.family)).collect()
}

/// Whether the level `at` names something `schema` has.
fn exists(schema: &Schema, set: &RuleSet, families: &HashMap<Id, String>, at: &Scope) -> bool {
    match at {
        Scope::Global | Scope::Schema => true,
        Scope::Namespace { namespace } => schema.namespaces.iter().any(|n| &n.id == namespace),
        Scope::Family { namespace, family } => {
            schema.tables.iter().any(|t| &t.namespace == namespace && families.get(&t.id).is_some_and(|f| f == family))
        }
        Scope::Group { group } => set.groups.iter().any(|g| &g.name == group),
        Scope::Table { table } => schema.tables.iter().any(|t| &t.id == table),
    }
}

/// Every table under the level `at`.
fn under<'a>(schema: &'a Schema, set: &RuleSet, families: &HashMap<Id, String>, at: &Scope) -> Vec<&'a Table> {
    let fam: HashMap<&Id, &str> = families.iter().map(|(k, v)| (k, v.as_str())).collect();
    schema.tables.iter().filter(|t| chain(schema, &fam, &set.groups, t).contains(at)).collect()
}

/// Whether `link` may be added to `set`: its rule and level exist, an exception has a reason and switches off
/// something that reaches every table under it, and nothing locked above is switched off.
///
/// # Errors
/// What is wrong with it, in a sentence.
pub fn admit(cat: &Catalog, schema: &Schema, global: &[Link], set: &RuleSet, link: &Link) -> Result<(), String> {
    well_formed(cat, link)?;
    let families = families(schema);
    if !exists(schema, set, &families, &link.at) {
        return Err(format!("{} is not in this schema", describe(&link.at)));
    }
    if set.links.iter().chain(global).any(|l| l.rule == link.rule && l.at == link.at) {
        return Err(format!("`{}` is already linked or switched off at {}", link.rule, describe(&link.at)));
    }
    let tables = under(schema, set, &families, &link.at);
    let fam: HashMap<&Id, &str> = families.iter().map(|(k, v)| (k, v.as_str())).collect();
    let all: Vec<&Link> = global.iter().chain(&set.links).collect();
    if !link.off {
        if link.locked {
            locks_no_exception(cat, schema, &fam, set, &all, link, &tables)?;
        }
        return Ok(());
    }
    if link.rule == ALL {
        // Rules are optional: a schema or a group may use none, locked or not.
        return Ok(());
    }
    for t in &tables {
        let chain = chain(schema, &fam, &set.groups, t);
        let upto: Vec<Scope> =
            chain.iter().take_while(|s| **s != link.at).cloned().chain(std::iter::once(link.at.clone())).collect();
        let eff = resolve(cat, &upto, &all);
        let holding: Vec<&Applied> = eff.applied.iter().filter(|a| cat.contains(&a.rule, &link.rule)).collect();
        if let Some(locked) = holding.iter().find(|a| a.locked) {
            return Err(format!(
                "`{}` is locked at {}: it cannot be switched off below",
                locked.rule,
                describe(&locked.from)
            ));
        }
        if holding.is_empty() {
            return Err(format!("`{}` does not reach `{}`, so there is nothing to switch off", link.rule, t.name));
        }
    }
    Ok(())
}

/// What every link must be, whatever schema it is on: a rule that exists, `*` only switched off, an exception
/// with a reason and never locked.
///
/// # Errors
/// What is wrong with it, in a sentence.
pub fn well_formed(cat: &Catalog, link: &Link) -> Result<(), String> {
    if link.rule == ALL && !link.off {
        return Err("every rule can only be switched off, not linked".to_string());
    }
    if link.rule != ALL && cat.rule(&link.rule).is_none() {
        return Err(format!("there is no rule `{}`", link.rule));
    }
    if link.off && link.locked {
        return Err("an exception cannot be locked".to_string());
    }
    if link.off && link.reason.as_deref().is_none_or(|r| r.trim().is_empty()) {
        return Err("an exception needs a reason".to_string());
    }
    Ok(())
}

/// A locked link may not sit above an exception that switches part of it off: the exception would stop
/// working while still being stored, so it is removed first.
fn locks_no_exception(
    cat: &Catalog,
    schema: &Schema,
    fam: &HashMap<&Id, &str>,
    set: &RuleSet,
    all: &[&Link],
    link: &Link,
    tables: &[&Table],
) -> Result<(), String> {
    for t in tables {
        let chain = chain(schema, fam, &set.groups, t);
        let below: Vec<&Scope> = chain.iter().skip_while(|s| **s != link.at).collect();
        let hit =
            all.iter().find(|e| e.off && e.rule != ALL && below.contains(&&e.at) && cat.contains(&link.rule, &e.rule));
        if let Some(e) = hit {
            return Err(format!(
                "`{}` is switched off at {}: remove that exception before locking `{}` above it",
                e.rule,
                describe(&e.at),
                link.rule
            ));
        }
    }
    Ok(())
}

/// Whether a goal still has `pack` to link to the whole schema: it is not linked there or to every schema, and
/// the schema does not switch it off.
#[must_use]
pub fn pack_open(global: &[Link], set: &RuleSet, pack: &str) -> bool {
    !set.links.iter().any(|l| l.rule == pack && l.at == Scope::Schema)
        && !global.iter().any(|l| l.rule == pack && !l.off)
}

/// A level in words, for messages: `namespace n_estate`, `group Streamed by CDC`.
#[must_use]
pub fn describe(at: &Scope) -> String {
    match at {
        Scope::Global => "every schema".to_string(),
        Scope::Schema => "the schema".to_string(),
        Scope::Namespace { namespace } => format!("namespace `{namespace}`"),
        Scope::Family { namespace, family } => format!("family `{family}` of `{namespace}`"),
        Scope::Group { group } => format!("group `{group}`"),
        Scope::Table { table } => format!("table `{table}`"),
    }
}

/// Checks `schema` against the rules linked to it (`set`) and to every schema (`global`).
#[must_use]
pub fn check(schema: &Schema, global: &[Link], set: &RuleSet) -> Report {
    let cat = catalog();
    let families = families(schema);
    let fam: HashMap<&Id, &str> = families.iter().map(|(k, v)| (k, v.as_str())).collect();
    let mut report = Report::default();
    for l in global.iter().chain(&set.links) {
        if l.rule != ALL && cat.rule(&l.rule).is_none() {
            report.problems.push(format!("there is no rule `{}`", l.rule));
        } else if !exists(schema, set, &families, &l.at) {
            report.problems.push(format!("`{}` is linked at {}, which is not in this schema", l.rule, describe(&l.at)));
        }
    }
    let links: Vec<&Link> = global.iter().chain(&set.links).collect();
    let mut runs: Vec<(&Table, Vec<&str>)> = Vec::new();
    for t in &schema.tables {
        let eff = resolve(cat, &chain(schema, &fam, &set.groups, t), &links);
        let checks = eff.checks(cat);
        report.tables.insert(t.id.clone(), eff);
        runs.push((t, checks));
    }
    let drift: Vec<&Table> = runs.iter().filter(|(_, c)| c.contains(&"types.drift")).map(|(t, _)| *t).collect();
    let cx = checks::Context::new(schema, &drift);
    for (t, list) in &runs {
        for id in list {
            let rule = cat.rule(id).expect("a check of the catalog");
            if !rule.targets.is_empty() && !rule.targets.contains(&schema.target) {
                continue;
            }
            let o = checks::run(id, &cx, t);
            let tally = report.tallies.entry((*id).to_string()).or_default();
            tally.checked += o.checked;
            tally.breaks += o.breaks.len();
            for (column, message) in o.breaks {
                report.findings.push(Finding { rule: (*id).to_string(), table: t.id.clone(), column, message });
            }
        }
    }
    // A pack's tally is its checks'.
    for r in cat.rules.iter().filter(|r| !r.rules.is_empty()) {
        let mut sum = Tally::default();
        let mut any = false;
        for c in cat.checks(&r.id) {
            if let Some(t) = report.tallies.get(c) {
                any = true;
                sum.checked += t.checked;
                sum.breaks += t.breaks;
            }
        }
        if any && report.tables.values().any(|e| e.applied.iter().any(|a| cat.contains(&a.rule, &r.id))) {
            report.tallies.insert(r.id.clone(), sum);
        }
    }
    report
}
