//! What each built-in check looks at in a table. A check says how many things it looked at and what breaks it.

use std::collections::{BTreeMap, HashMap};

use super::compat;
use crate::{DataType, Id, Schema, Table, Target};

/// What one check found in one table.
#[derive(Debug, Default)]
pub(super) struct Outcome {
    /// How many things it looked at (the table, its time columns, its columns).
    pub checked: usize,
    /// What breaks it: the column, when it is one, and what is wrong.
    pub breaks: Vec<(Option<Id>, String)>,
}

impl Outcome {
    fn look(&mut self) {
        self.checked += 1;
    }

    fn table(&mut self, message: String) {
        self.breaks.push((None, message));
    }

    fn column(&mut self, column: &Id, message: String) {
        self.breaks.push((Some(column.clone()), message));
    }
}

/// What the checks share about the whole schema.
pub(super) struct Context<'a> {
    pub schema: &'a Schema,
    /// Tables by their name's key (`stores` for `tbl_Stores`), per namespace.
    by_key: HashMap<(&'a Id, String), &'a Table>,
    /// Each column name's types, over the tables `types.drift` covers: how many columns have each.
    names: HashMap<String, BTreeMap<String, usize>>,
}

impl<'a> Context<'a> {
    pub fn new(schema: &'a Schema, drift_tables: &[&'a Table]) -> Self {
        let mut by_key = HashMap::new();
        for t in &schema.tables {
            by_key.entry((&t.namespace, key(&t.name))).or_insert(t);
        }
        let mut names: HashMap<String, BTreeMap<String, usize>> = HashMap::new();
        for t in drift_tables {
            for c in &t.columns {
                *names.entry(c.name.to_lowercase()).or_default().entry(label(&c.data_type)).or_default() += 1;
            }
        }
        Self { schema, by_key, names }
    }

    /// The table a name points at in `table`'s namespace: `node` or `nodes` for `nodes`.
    fn table_named(&self, table: &Table, base: &str) -> Option<&'a Table> {
        let plural = |b: &str| {
            [
                b.to_string(),
                format!("{b}s"),
                format!("{b}es"),
                b.strip_suffix('y').map(|s| format!("{s}ies")).unwrap_or_default(),
            ]
        };
        plural(base)
            .into_iter()
            .filter(|k| !k.is_empty())
            .find_map(|k| self.by_key.get(&(&table.namespace, k)).copied())
            .filter(|t| t.id != table.id)
    }

    /// Columns that copy an attribute of a table their name points at: `version_calls` copies `versions.calls`.
    fn copies(&self, table: &'a Table) -> Vec<(&'a crate::Column, &'a Table, String)> {
        let mut out = Vec::new();
        for c in &table.columns {
            let lower = c.name.to_lowercase();
            let parts: Vec<&str> = lower.split('_').filter(|p| !p.is_empty()).collect();
            for i in 1..parts.len() {
                let (base, attr) = (parts[..i].join("_"), parts[i..].join("_"));
                if attr == "id" || attr == "key" {
                    continue;
                }
                if let Some(source) = self.table_named(table, &base)
                    && source.columns.iter().any(|s| s.name.to_lowercase() == attr)
                {
                    out.push((c, source, attr));
                    break;
                }
            }
        }
        out
    }
}

/// A table's name as other names point at it: its words without a `tbl` prefix, lower case, run together.
fn key(name: &str) -> String {
    let lower = name.to_lowercase();
    let trimmed = lower.strip_prefix("tbl_").unwrap_or(&lower);
    trimmed.replace("__", "_")
}

/// A type as one comparable label: `varchar(255)`, `decimal(18,2)`, `list<string>`.
fn label(t: &DataType) -> String {
    let mut s = t.name.clone();
    if t.is_verbatim() {
        return t.text.clone().unwrap_or(s);
    }
    if t.unsigned {
        s.push_str(" unsigned");
    }
    if t.with_time_zone {
        s.push_str(" tz");
    }
    match (t.length, t.precision, t.scale) {
        (Some(l), _, _) => s.push_str(&format!("({l})")),
        (_, Some(p), Some(sc)) => s.push_str(&format!("({p},{sc})")),
        (_, Some(p), None) => s.push_str(&format!("({p})")),
        _ => {}
    }
    if let Some(of) = &t.of {
        s.push_str(&format!("<{}>", label(of)));
    }
    if !t.fields.is_empty() {
        s.push_str(&format!("<{} fields>", t.fields.len()));
    }
    s
}

fn is_string(t: &DataType) -> bool {
    matches!(t.name.as_str(), "string" | "varchar" | "char" | "text" | "tinytext" | "mediumtext" | "longtext")
}

fn looks_like_time(name: &str) -> bool {
    let n = name.to_lowercase();
    ["_at", "_utc", "_time", "_ts", "_timestamp", "_datetime", "_date"].iter().any(|s| n.ends_with(s))
        || matches!(n.as_str(), "timestamp" | "created" | "updated" | "modified")
}

const MONEY: &[&str] = &["amount", "price", "cost", "total", "balance", "fee", "revenue", "salary", "money"];

/// The key a table has: its primary key, its Iceberg identifier fields, or a required `id` column.
fn key_columns(t: &Table) -> Vec<&crate::Column> {
    let ids: Vec<&Id> = if let Some(pk) = &t.primary_key {
        pk.columns.iter().collect()
    } else if let Some(ice) = t.options.iceberg.as_ref().filter(|i| !i.identifier_fields.is_empty()) {
        ice.identifier_fields.iter().collect()
    } else {
        return t.columns.iter().filter(|c| c.name == "id" && !c.nullable).collect();
    };
    t.columns.iter().filter(|c| ids.contains(&&c.id)).collect()
}

const POSITION: &[&str] = &[
    "source_ts_ms",
    "__source_ts_ms",
    "_source_ts_ms",
    "source_ts",
    "source_lsn",
    "__lsn",
    "_lsn",
    "binlog_position",
    "binlog_pos",
    "__ts_ms",
    "_cdc_ts",
    "cdc_ts",
];

/// Runs check `id` on `table`; a check it does not know looks at nothing.
pub(super) fn run(id: &str, cx: &Context<'_>, table: &Table) -> Outcome {
    let mut o = Outcome::default();
    let target = cx.schema.target;
    match id {
        "types.time" => {
            for c in table.columns.iter().filter(|c| looks_like_time(&c.name)) {
                o.look();
                if is_string(&c.data_type) {
                    o.column(
                        &c.id,
                        format!("`{}` holds a time as {}: make it a timestamp", c.name, label(&c.data_type)),
                    );
                }
            }
        }
        "types.drift" => {
            for c in &table.columns {
                let Some(types) = cx.names.get(&c.name.to_lowercase()) else { continue };
                if types.values().sum::<usize>() < 2 {
                    continue;
                }
                o.look();
                let mine = label(&c.data_type);
                let (most, _) = types.iter().max_by_key(|(_, n)| **n).expect("a type");
                if types.len() > 1 && &mine != most {
                    let others: Vec<String> =
                        types.iter().filter(|(l, _)| **l != mine).map(|(l, n)| format!("{l} in {n}")).collect();
                    o.column(&c.id, format!("`{}` is {mine} here; elsewhere {}", c.name, others.join(", ")));
                }
            }
        }
        "types.money" => {
            for c in &table.columns {
                let lower = c.name.to_lowercase();
                if !lower.split('_').any(|w| MONEY.contains(&w)) {
                    continue;
                }
                o.look();
                if matches!(c.data_type.name.as_str(), "float" | "double" | "real" | "double precision") {
                    o.column(&c.id, format!("`{}` holds money as {}: make it a decimal", c.name, c.data_type.name));
                }
            }
        }
        "pk.present" => {
            o.look();
            if key_columns(table).is_empty() {
                o.table(format!("`{}` has no key", table.name));
            }
        }
        "pk.required" => {
            let key = key_columns(table);
            if !key.is_empty() {
                o.look();
                for c in key.into_iter().filter(|c| c.nullable) {
                    o.column(&c.id, format!("key column `{}` may be empty", c.name));
                }
            }
        }
        "pk.ident" if target == Target::Iceberg => {
            o.look();
            if table.options.iceberg.as_ref().is_none_or(|i| i.identifier_fields.is_empty()) {
                o.table(format!("`{}` declares no identifier fields", table.name));
            }
        }
        "naming.case" => {
            let snake = |n: &str| {
                n.chars().next().is_some_and(|c| c.is_ascii_lowercase())
                    && n.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
            };
            o.look();
            if !snake(&table.name) {
                o.table(format!("table `{}` is not snake_case", table.name));
            }
            for c in &table.columns {
                o.look();
                if !snake(&c.name) {
                    o.column(&c.id, format!("`{}` is not snake_case", c.name));
                }
            }
        }
        "docs.table" => {
            o.look();
            if table.comment.as_deref().is_none_or(|c| c.trim().is_empty()) {
                o.table(format!("`{}` has no description", table.name));
            }
        }
        "docs.column" => {
            for c in &table.columns {
                o.look();
                if c.comment.as_deref().is_none_or(|t| t.trim().is_empty()) {
                    o.column(&c.id, format!("`{}` has no description", c.name));
                }
            }
        }
        "norm.repeat" => {
            o.look();
            let mut groups: BTreeMap<String, Vec<&str>> = BTreeMap::new();
            for c in &table.columns {
                let stem = c.name.trim_end_matches(|ch: char| ch.is_ascii_digit());
                if stem.len() < c.name.len() && !stem.trim_end_matches('_').is_empty() {
                    groups.entry(stem.trim_end_matches('_').to_lowercase()).or_default().push(&c.name);
                }
            }
            for (stem, names) in groups.into_iter().filter(|(_, n)| n.len() >= 3) {
                o.table(format!(
                    "{} columns of one kind (`{}` … `{}`): a child table holds any number of `{stem}`",
                    names.len(),
                    names[0],
                    names[names.len() - 1]
                ));
            }
        }
        "norm.copies" => {
            o.look();
            for (c, source, attr) in cx.copies(table) {
                o.column(&c.id, format!("`{}` copies `{}.{attr}`", c.name, source.name));
            }
        }
        "norm.lists" => {
            for c in table.columns.iter().filter(|c| is_string(&c.data_type)) {
                o.look();
                let n = c.name.to_lowercase();
                if n.ends_with("_ids") || n.ends_with("_list") || n.ends_with("_csv") {
                    o.column(&c.id, format!("`{}` keeps a list in a string", c.name));
                }
            }
        }
        "denorm.source" => {
            for (c, source, attr) in cx.copies(table) {
                o.look();
                let named =
                    c.comment.as_deref().is_some_and(|t| t.to_lowercase().contains(&source.name.to_lowercase()));
                if !named {
                    o.column(
                        &c.id,
                        format!("`{}` copies `{}.{attr}` but its description does not say so", c.name, source.name),
                    );
                }
            }
        }
        "scd2.columns" | "audit.columns" => {
            o.look();
            let need: &[&str] =
                if id == "scd2.columns" { &["valid_from", "valid_to"] } else { &["created_at", "updated_at"] };
            let missing: Vec<&str> =
                need.iter().copied().filter(|n| !table.columns.iter().any(|c| c.name == *n)).collect();
            if !missing.is_empty() {
                o.table(format!("`{}` has no {}", table.name, missing.join(" or ")));
            }
        }
        "mor.modes" if target == Target::Iceberg => {
            o.look();
            let props = table.options.iceberg.as_ref().map(|i| &i.properties);
            let off: Vec<&str> = ["write.delete.mode", "write.update.mode", "write.merge.mode"]
                .into_iter()
                .filter(|k| props.and_then(|p| p.get(*k)).is_none_or(|v| v != "merge-on-read"))
                .collect();
            if !off.is_empty() {
                o.table(format!("`{}` is not merge-on-read for {}", table.name, off.join(", ")));
            }
        }
        "idx.related" if target != Target::Iceberg => {
            // Each relationship from this table: its columns lead an index or the key.
            let leads = |cols: &[Id]| {
                let starts = |parts: Vec<Option<&Id>>| {
                    cols.iter().enumerate().all(|(i, c)| parts.get(i).copied().flatten() == Some(c))
                };
                table.primary_key.as_ref().is_some_and(|pk| starts(pk.columns.iter().map(Some).collect()))
                    || table.indexes.iter().any(|ix| starts(ix.parts.iter().map(|p| p.column.as_ref()).collect()))
                    || table.uniques.iter().any(|u| starts(u.columns.iter().map(Some).collect()))
            };
            for r in cx.schema.relationships.iter().filter(|r| r.from.table == table.id) {
                o.look();
                if !leads(&r.from.columns) {
                    let names: Vec<&str> = r
                        .from
                        .columns
                        .iter()
                        .filter_map(|c| table.columns.iter().find(|x| &x.id == c))
                        .map(|c| c.name.as_str())
                        .collect();
                    o.table(format!("`{}` ({}) joins another table with no index", table.name, names.join(", ")));
                }
            }
        }
        "idx.redundant" if target != Target::Iceberg => {
            let cols = |ix: &crate::Index| ix.parts.iter().map(|p| p.column.clone()).collect::<Vec<_>>();
            let pk: Option<Vec<Option<Id>>> =
                table.primary_key.as_ref().map(|k| k.columns.iter().cloned().map(Some).collect());
            for ix in
                table.indexes.iter().filter(|ix| ix.predicate.is_none() && ix.parts.iter().all(|p| p.column.is_some()))
            {
                o.look();
                let mine = cols(ix);
                let covered_by = table
                    .indexes
                    .iter()
                    .filter(|other| other.id != ix.id && other.predicate.is_none())
                    .map(|other| (other.name.clone(), cols(other)))
                    .chain(pk.clone().map(|k| ("the primary key".to_string(), k)))
                    .find(|(_, other)| {
                        other.len() >= mine.len()
                            && other[..mine.len()] == mine[..]
                            && (other.len() > mine.len() || !ix.unique)
                    });
                if let Some((by, _)) = covered_by {
                    o.table(format!("index `{}` on `{}` repeats the start of {by}", ix.name, table.name));
                }
            }
        }
        "idx.pk_narrow" if target == Target::Mysql => {
            if let Some(pk) = &table.primary_key {
                o.look();
                let wide: Vec<&str> = pk
                    .columns
                    .iter()
                    .filter_map(|c| table.columns.iter().find(|x| &x.id == c))
                    .filter(|c| {
                        matches!(
                            c.data_type.name.as_str(),
                            "tinytext"
                                | "text"
                                | "mediumtext"
                                | "longtext"
                                | "blob"
                                | "mediumblob"
                                | "longblob"
                                | "json"
                        ) || c.data_type.length.is_some_and(|l| l > 64)
                    })
                    .map(|c| c.name.as_str())
                    .collect();
                if !wide.is_empty() || pk.columns.len() > 3 {
                    o.table(format!(
                        "`{}`'s primary key is wide ({}): every secondary index carries it",
                        table.name,
                        if wide.is_empty() { format!("{} columns", pk.columns.len()) } else { wide.join(", ") }
                    ));
                }
            }
        }
        "mysql.engine" if target == Target::Mysql => {
            o.look();
            if let Some(engine) = table.options.mysql.as_ref().and_then(|m| m.engine.as_deref())
                && !engine.eq_ignore_ascii_case("innodb")
            {
                o.table(format!("`{}` uses {engine}", table.name));
            }
        }
        "mysql.charset" if target == Target::Mysql => {
            let not_mb4 = |c: &str| !c.to_lowercase().starts_with("utf8mb4");
            o.look();
            if let Some(cs) = table.options.mysql.as_ref().and_then(|m| m.charset.as_deref()).filter(|c| not_mb4(c)) {
                o.table(format!("`{}` is {cs}", table.name));
            }
            for c in table.columns.iter().filter(|c| c.data_type.charset.is_some()) {
                o.look();
                if let Some(cs) = c.data_type.charset.as_deref().filter(|c| not_mb4(c)) {
                    o.column(&c.id, format!("`{}` is {cs}", c.name));
                }
            }
        }
        "pg.timestamptz" if target == Target::Postgres => {
            for c in table.columns.iter().filter(|c| c.data_type.name == "timestamp") {
                o.look();
                if !c.data_type.with_time_zone {
                    o.column(&c.id, format!("`{}` is a timestamp without a zone", c.name));
                }
            }
        }
        "pg.identity" if target == Target::Postgres => {
            for c in &table.columns {
                let sequence = matches!(c.data_type.name.as_str(), "serial" | "bigserial" | "smallserial")
                    || c.default.as_deref().is_some_and(|d| d.contains("nextval("));
                if sequence {
                    o.look();
                    o.column(
                        &c.id,
                        format!("`{}` takes its value from a sequence: make it an identity column", c.name),
                    );
                } else if c.identity.is_some() {
                    o.look();
                }
            }
        }
        "iceberg.format" if target == Target::Iceberg => {
            o.look();
            if table.options.iceberg.as_ref().and_then(|i| i.format_version).is_none_or(|v| v < 2) {
                o.table(format!("`{}` sets no format version of 2 or more", table.name));
            }
        }
        "cdc.position" if target == Target::Iceberg => {
            o.look();
            if !table.columns.iter().any(|c| POSITION.contains(&c.name.to_lowercase().as_str())) {
                o.table(format!("`{}` keeps no change position or time (e.g. source_ts_ms, source_lsn)", table.name));
            }
        }
        "cdc.source" if target != Target::Iceberg => {
            for c in &table.columns {
                o.look();
                let t = &c.data_type;
                let why = match (target, t.name.as_str()) {
                    (Target::Mysql, "bigint") if t.unsigned => {
                        Some("arrives wrong above 2^63 unless bigint.unsigned.handling.mode is precise")
                    }
                    (Target::Mysql, "time") => Some("arrives wrong beyond 24 hours"),
                    (Target::Mysql, "enum" | "set") => Some("a change to its values changes what consumers receive"),
                    (Target::Postgres, "numeric") if t.precision.is_none() => {
                        Some("arrives with a different scale per value: give it a precision")
                    }
                    (Target::Postgres, "interval") => Some("arrives as microseconds, months approximated"),
                    (Target::Postgres, "time") if t.with_time_zone => Some("arrives as a string"),
                    (Target::Postgres, "money") => Some("takes its scale from money.fraction.digits"),
                    _ => None,
                };
                if let Some(why) = why {
                    o.column(&c.id, format!("`{}` ({}) {why}", c.name, label(t)));
                }
            }
        }
        _ => {
            if let Some(rest) = id.strip_prefix("compat.") {
                compatible(rest, target, table, &mut o);
            }
        }
    }
    o
}

/// `compat.<pair>.lossy` and `.decide`: each column graded by the pair's map.
fn compatible(rest: &str, target: Target, table: &Table, o: &mut Outcome) {
    let Some((pair, which)) = rest.rsplit_once('.') else { return };
    let Some(map) = compat::MAPS.iter().find(|m| m.id == pair) else { return };
    if map.from != target {
        return;
    }
    let to = match map.to {
        Target::Mysql => "MySQL",
        Target::Postgres => "PostgreSQL",
        Target::Iceberg => "Iceberg",
    };
    for c in &table.columns {
        o.look();
        let Some(row) = map.row(&c.data_type) else { continue };
        let hit = match which {
            "lossy" => matches!(row.grade, compat::Grade::Lossy | compat::Grade::None),
            "decide" => row.grade == compat::Grade::Decide,
            _ => false,
        };
        if hit {
            let why = if row.why.is_empty() { String::new() } else { format!(": {}", row.why) };
            o.column(&c.id, format!("`{}` ({}) becomes {} in {to}{why}", c.name, label(&c.data_type), row.to));
        }
    }
}
