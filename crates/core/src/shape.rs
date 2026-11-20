//! A schema as the perspectives show it: the families its tables fall into, the dated or temporary copies that
//! stack under one table, and the links between tables, declared or read from column names (docs/perspectives.md).
//!
//! Nothing here changes the model; it is read from it, the same way every time, so a perspective drawn from it
//! never moves on its own.

use std::collections::{BTreeMap, HashMap, HashSet};

use serde::Serialize;

use crate::{Id, Schema, Table};

/// Tables in a family name that groups the ones sharing no word with at least three others.
pub const UNGROUPED: &str = "ungrouped";
/// The one family of a namespace small enough to need none.
pub const ALL_TABLES: &str = "tables";
/// A namespace this small is one family.
const SMALL_NAMESPACE: usize = 12;
/// A word makes a family when at least this many tables start with it.
const FAMILY_MIN: usize = 4;
/// A table more tables point at than this (and than this share of its namespace) is a shared key: its links are
/// noted on each table rather than drawn as a crowd of lines.
const SHARED_MIN: usize = 25;
const SHARED_SHARE: f64 = 0.15;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Shape {
    pub tables: Vec<TableShape>,
    pub families: Vec<Family>,
    pub links: Vec<Link>,
}

/// Where a table sits: its family, and the copies it stands for or the table it is a copy of.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TableShape {
    pub table: Id,
    pub family: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub copy_of: Option<Id>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stack: Option<Stack>,
}

/// A table and its copies: a monthly, daily or yearly series, or copies under temporary names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Stack {
    /// The name the copies share (`tbl_ShipDetails`).
    pub series: String,
    /// The stack in words (`tbl_ShipDetails · 5 yearly, 2022 → 2026`).
    pub label: String,
    /// How many tables it holds, this one included.
    pub count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Family {
    pub namespace: Id,
    pub name: String,
    pub tables: usize,
    pub copies: usize,
}

/// A table that refers to another through one of its columns.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Link {
    pub from: Id,
    pub column: Id,
    pub to: Id,
    /// A relationship in the model, not one read from the names.
    pub declared: bool,
    /// Into a table most tables point at: shown as a note, not a line.
    pub shared: bool,
}

#[must_use]
pub fn shape(schema: &Schema) -> Shape {
    let copy_of = copies(&schema.tables);
    let mut stacks = stack_labels(&schema.tables, &copy_of);
    let family = families(schema, &copy_of);
    let links = links(schema, &copy_of);
    let mut fams: BTreeMap<(Id, String), (usize, usize)> = BTreeMap::new();
    for t in &schema.tables {
        let main = copy_of.get(&t.id).unwrap_or(&t.id);
        let f = family.get(main).cloned().unwrap_or_else(|| UNGROUPED.to_string());
        let e = fams.entry((t.namespace.clone(), f)).or_default();
        if copy_of.contains_key(&t.id) { e.1 += 1 } else { e.0 += 1 }
    }
    Shape {
        tables: schema
            .tables
            .iter()
            .map(|t| TableShape {
                table: t.id.clone(),
                family: family
                    .get(copy_of.get(&t.id).unwrap_or(&t.id))
                    .cloned()
                    .unwrap_or_else(|| UNGROUPED.to_string()),
                copy_of: copy_of.get(&t.id).cloned(),
                stack: stacks.remove(&t.id),
            })
            .collect(),
        families: fams
            .into_iter()
            .map(|((namespace, name), (tables, copies))| Family { namespace, name, tables, copies })
            .collect(),
        links,
    }
}

/// `tbl_ShipDetails2022` → `tbl`, `Call`, `Details`, `2022`; `node__accounts` → `node`, `accounts`.
fn words(name: &str) -> Vec<String> {
    let chars: Vec<char> = name.chars().collect();
    let mut out = Vec::new();
    let mut cur = String::new();
    for (i, &c) in chars.iter().enumerate() {
        if c == '_' {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            continue;
        }
        if let Some(p) = cur.chars().last() {
            let next_lower = chars.get(i + 1).is_some_and(|n| n.is_lowercase());
            let split = (p.is_lowercase() && c.is_uppercase())
                || (p.is_uppercase() && c.is_uppercase() && next_lower)
                || (p.is_alphabetic() && c.is_ascii_digit());
            if split {
                out.push(std::mem::take(&mut cur));
            }
        }
        cur.push(c);
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

const TEMPORARY: [&str; 20] = [
    "old", "bak", "backup", "copy", "new", "tmp", "temp", "test", "jan", "feb", "mar", "apr", "may", "jun", "jul",
    "aug", "sep", "oct", "nov", "dec",
];

/// A name without the suffixes that make it a copy: `_old`, `_Jun`, `2022`, `_3`.
fn stem(name: &str) -> &str {
    let mut s = name;
    loop {
        let before = s;
        if let Some((head, tail)) = s.rsplit_once('_')
            && !head.is_empty()
            && (TEMPORARY.contains(&tail.to_lowercase().as_str())
                || (!tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit())))
        {
            s = head;
        } else {
            let digits = s.len() - s.trim_end_matches(|c: char| c.is_ascii_digit()).len();
            if (4..=8).contains(&digits) && digits < s.len() {
                s = &s[..s.len() - digits];
            }
        }
        if s == before {
            return s;
        }
    }
}

/// Each copy, and the table it is a copy of: tables of a namespace sharing a stem stack under the plainest name.
fn copies(tables: &[Table]) -> HashMap<Id, Id> {
    let mut groups: BTreeMap<(Id, String), Vec<&Table>> = BTreeMap::new();
    for t in tables {
        groups.entry((t.namespace.clone(), stem(&t.name).to_lowercase())).or_default().push(t);
    }
    let mut out = HashMap::new();
    for group in groups.values().filter(|g| g.len() > 1) {
        let main = group.iter().min_by_key(|t| (t.name.len(), t.name.as_str())).expect("a group of two");
        for t in group {
            if t.id != main.id {
                out.insert(t.id.clone(), main.id.clone());
            }
        }
    }
    out
}

/// The trailing date of a name, if it ends in one: `202203`, `2024`, `20240101`.
fn trailing_date(name: &str) -> Option<&str> {
    let digits = name.len() - name.trim_end_matches(|c: char| c.is_ascii_digit()).len();
    (4..=8).contains(&digits).then(|| &name[name.len() - digits..])
}

fn stack_labels(tables: &[Table], copy_of: &HashMap<Id, Id>) -> HashMap<Id, Stack> {
    let mut members: HashMap<&Id, Vec<&Table>> = HashMap::new();
    for t in tables {
        if let Some(main) = copy_of.get(&t.id) {
            members.entry(main).or_default().push(t);
        }
    }
    let by_id: HashMap<&Id, &Table> = tables.iter().map(|t| (&t.id, t)).collect();
    members
        .into_iter()
        .map(|(main, copies)| {
            let main_t = by_id[main];
            let all: Vec<&Table> = std::iter::once(main_t).chain(copies).collect();
            let series = stem(&main_t.name).to_string();
            let mut dated: Vec<&str> = all.iter().filter_map(|t| trailing_date(&t.name)).collect();
            dated.sort_unstable();
            let label = if dated.len() >= 2 && dated.len() + 1 >= all.len() {
                let span = match dated[0].len() {
                    6 => "monthly",
                    8 => "daily",
                    _ => "yearly",
                };
                let fmt = |d: &str| match d.len() {
                    6 => format!("{}-{}", &d[..4], &d[4..]),
                    8 => format!("{}-{}-{}", &d[..4], &d[4..6], &d[6..]),
                    _ => d.to_string(),
                };
                format!("{series} · {} {span}, {} → {}", all.len(), fmt(dated[0]), fmt(dated[dated.len() - 1]))
            } else {
                format!("{series} · {} copies", all.len())
            };
            (main.clone(), Stack { series, label, count: all.len() })
        })
        .collect()
}

/// The family of each table that is not a copy: a `prefix__` its name starts with, else the first word after a
/// prefix most of its namespace shares, when enough tables start with it.
fn families(schema: &Schema, copy_of: &HashMap<Id, Id>) -> HashMap<Id, String> {
    let mut out = HashMap::new();
    for ns in &schema.namespaces {
        let members: Vec<&Table> =
            schema.tables.iter().filter(|t| t.namespace == ns.id && !copy_of.contains_key(&t.id)).collect();
        if members.len() <= SMALL_NAMESPACE {
            for t in &members {
                out.insert(t.id.clone(), ALL_TABLES.to_string());
            }
            continue;
        }
        let mut heads: HashMap<String, usize> = HashMap::new();
        for t in &members {
            if let Some(w) = words(&t.name).first() {
                *heads.entry(w.to_lowercase()).or_default() += 1;
            }
        }
        let shared = heads
            .iter()
            .max_by_key(|(w, n)| (**n, std::cmp::Reverse((*w).clone())))
            .filter(|(_, n)| **n * 2 > members.len())
            .map(|(w, _)| w.clone());
        let raw: Vec<(Id, String)> = members
            .iter()
            .map(|t| {
                let f = if let Some((prefix, _)) = t.name.split_once("__") {
                    format!("{prefix}__")
                } else {
                    let mut w = words(&t.name);
                    if shared.as_deref().is_some_and(|p| w.first().is_some_and(|f| f.to_lowercase() == p))
                        && w.len() > 1
                    {
                        w.remove(0);
                    }
                    w.into_iter().next().unwrap_or_else(|| t.name.clone())
                };
                (t.id.clone(), f)
            })
            .collect();
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for (_, f) in &raw {
            *counts.entry(f.as_str()).or_default() += 1;
        }
        for (id, f) in &raw {
            let name = if counts[f.as_str()] >= FAMILY_MIN { f.clone() } else { UNGROUPED.to_string() };
            out.insert(id.clone(), name);
        }
    }
    out
}

/// The words of a table's name that say what it holds, run together: `tbl_Stores` → `stores`.
fn table_key(name: &str) -> String {
    words(name).into_iter().map(|w| w.to_lowercase()).filter(|w| w != "tbl").collect()
}

/// The table a column's name points at: `node_id`, `StoreKey`, `PromotionID` name `nodes`, `tbl_Stores`,
/// `tbl_Promotions` (singular or plural) in the same namespace.
fn named_target<'a>(table: &Table, column: &str, keys: &HashMap<(&Id, String), &'a Table>) -> Option<&'a Table> {
    let rest = ["Master", "Alternate", "Parent"].iter().find_map(|p| column.strip_prefix(p)).unwrap_or(column);
    let base = ["_id", "Key", "ID", "Id"].iter().find_map(|s| rest.strip_suffix(s)).filter(|b| !b.is_empty())?;
    let base: String = words(base).into_iter().map(|w| w.to_lowercase()).collect();
    if base.is_empty() {
        return None;
    }
    let mut candidates = vec![format!("{base}s"), base.clone(), format!("{base}es")];
    if let Some(stem) = base.strip_suffix('y') {
        candidates.push(format!("{stem}ies"));
    }
    candidates.into_iter().filter_map(|k| keys.get(&(&table.namespace, k)).copied()).find(|t| t.id != table.id)
}

/// Whether `text` names `word` as a whole word.
fn mentions(text: &str, word: &str) -> bool {
    let inside = |c: char| c.is_alphanumeric() || c == '_';
    text.match_indices(word).any(|(i, _)| {
        let before = text[..i].chars().next_back();
        let after = text[i + word.len()..].chars().next();
        !before.is_some_and(inside) && !after.is_some_and(inside)
    })
}

fn links(schema: &Schema, copy_of: &HashMap<Id, Id>) -> Vec<Link> {
    let main_of = |id: &Id| copy_of.get(id).cloned().unwrap_or_else(|| id.clone());
    let mut out: Vec<Link> = Vec::new();
    let mut seen: HashSet<(Id, Id, Id)> = HashSet::new();
    let mut push = |out: &mut Vec<Link>, from: &Id, column: &Id, to: Id, declared: bool| {
        if copy_of.contains_key(from) || *from == to {
            return;
        }
        if seen.insert((from.clone(), column.clone(), to.clone())) {
            out.push(Link { from: from.clone(), column: column.clone(), to, declared, shared: false });
        }
    };
    let mut declared_cols: HashSet<(Id, Id)> = HashSet::new();
    for r in &schema.relationships {
        if let Some(c) = r.from.columns.first() {
            declared_cols.insert((r.from.table.clone(), c.clone()));
            push(&mut out, &r.from.table, c, main_of(&r.to.table), true);
        }
    }
    let keys: HashMap<(&Id, String), &Table> = schema
        .tables
        .iter()
        .filter(|t| !copy_of.contains_key(&t.id))
        .map(|t| ((&t.namespace, table_key(&t.name)), t))
        .collect();
    let mut by_length: Vec<&Table> = schema.tables.iter().filter(|t| !copy_of.contains_key(&t.id)).collect();
    by_length.sort_by_key(|t| std::cmp::Reverse(t.name.len()));
    for t in schema.tables.iter().filter(|t| !copy_of.contains_key(&t.id)) {
        for c in &t.columns {
            if declared_cols.contains(&(t.id.clone(), c.id.clone())) {
                continue;
            }
            if let Some(target) = named_target(t, &c.name, &keys) {
                push(&mut out, &t.id, &c.id, target.id.clone(), false);
            } else if c.name.ends_with("_id") && c.name != "id" {
                // A reference whose name says nothing, whose description names the table.
                let text = c.comment.as_deref().unwrap_or_default();
                for other in by_length.iter().filter(|o| o.id != t.id && mentions(text, &o.name)).take(3) {
                    push(&mut out, &t.id, &c.id, other.id.clone(), false);
                }
            }
        }
    }
    // Shared keys: a table most of its namespace points at.
    let ns_size: HashMap<&Id, usize> = schema.tables.iter().fold(HashMap::new(), |mut m, t| {
        *m.entry(&t.namespace).or_default() += 1;
        m
    });
    let ns_of: HashMap<&Id, &Id> = schema.tables.iter().map(|t| (&t.id, &t.namespace)).collect();
    let mut into: HashMap<Id, usize> = HashMap::new();
    for l in &out {
        *into.entry(l.to.clone()).or_default() += 1;
    }
    for l in &mut out {
        let size = ns_of.get(&l.to).and_then(|ns| ns_size.get(ns)).copied().unwrap_or(0);
        #[allow(clippy::cast_precision_loss)]
        let limit = (SHARED_MIN as f64).max(size as f64 * SHARED_SHARE);
        #[allow(clippy::cast_precision_loss)]
        let n = into[&l.to] as f64;
        l.shared = !l.declared && n > limit;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_split_the_ways_names_are_written() {
        assert_eq!(words("tbl_ShipDetails2022"), ["tbl", "Ship", "Details", "2022"]);
        assert_eq!(words("node__accounts"), ["node", "accounts"]);
        assert_eq!(words("HTTPServerLog"), ["HTTP", "Server", "Log"]);
    }

    #[test]
    fn stems_drop_dates_and_temporary_suffixes_but_not_words() {
        assert_eq!(stem("tbl_ShipDetails2022"), "tbl_ShipDetails");
        assert_eq!(stem("tbl_PriceLists_Jun"), "tbl_PriceLists");
        assert_eq!(stem("tbl_ReturnRules_old"), "tbl_ReturnRules");
        assert_eq!(stem("tbl_Renew"), "tbl_Renew");
        assert_eq!(stem("orders_3"), "orders");
        assert_eq!(stem("node__accounts"), "node__accounts");
    }

    #[test]
    fn mentions_whole_words_only() {
        assert!(mentions("the id of this node's row in nodes", "nodes"));
        assert!(!mentions("node__nodes is not it", "nodes_x"));
        assert!(!mentions("vectors__nodes", "nodes"));
    }
}
