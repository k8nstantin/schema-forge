//! Writing an Iceberg schema as Spark SQL: one `CREATE TABLE … USING iceberg` per table, its sort order and
//! identifier fields as `ALTER TABLE`, its views, its kept statements in their places.

use std::collections::HashMap;
use std::fmt::Write as _;

use schema_forge_core::{Direction, Id, Nulls, Schema, Table, View};

use super::types::{quote, write as write_type};

/// The whole schema as Spark SQL.
#[must_use]
pub fn generate(schema: &Schema) -> String {
    let mut out = String::new();
    let paths = namespace_paths(schema);
    for k in schema.kept.iter().filter(|k| k.after.is_none()) {
        let _ = writeln!(out, "{};\n", k.text);
    }
    for t in &schema.tables {
        out.push_str(&table(schema, &paths, t));
        kept_after(schema, &t.id, &mut out);
    }
    for v in &schema.views {
        out.push_str(&view(&paths, v));
        kept_after(schema, &v.id, &mut out);
    }
    out
}

fn kept_after(schema: &Schema, id: &Id, out: &mut String) {
    for k in schema.kept.iter().filter(|k| k.after.as_ref() == Some(id)) {
        let _ = writeln!(out, "{};\n", k.text);
    }
}

/// Each namespace's full path, outermost first.
fn namespace_paths(schema: &Schema) -> HashMap<Id, Vec<String>> {
    let by_id: HashMap<&Id, &schema_forge_core::Namespace> = schema.namespaces.iter().map(|n| (&n.id, n)).collect();
    let mut out = HashMap::new();
    for n in &schema.namespaces {
        let mut path = vec![n.name.clone()];
        let mut parent = n.parent.as_ref();
        while let Some(p) = parent.and_then(|p| by_id.get(p)) {
            path.insert(0, p.name.clone());
            parent = p.parent.as_ref();
        }
        out.insert(n.id.clone(), path);
    }
    out
}

fn name(paths: &HashMap<Id, Vec<String>>, namespace: &Id, object: &str) -> String {
    let mut parts: Vec<String> = paths.get(namespace).cloned().unwrap_or_default();
    parts.push(object.to_string());
    parts.iter().map(|p| format!("`{}`", p.replace('`', "``"))).collect::<Vec<_>>().join(".")
}

fn notes(notes: Option<&String>, out: &mut String) {
    if let Some(n) = notes {
        for line in n.lines() {
            if line.is_empty() {
                out.push_str("--\n");
            } else {
                let _ = writeln!(out, "-- {line}");
            }
        }
    }
}

/// One table: `CREATE TABLE`, then its sort order and identifier fields.
#[must_use]
pub fn table(schema: &Schema, paths: &HashMap<Id, Vec<String>>, t: &Table) -> String {
    let mut out = String::new();
    notes(t.notes.as_ref(), &mut out);
    let full = name(paths, &t.namespace, &t.name);
    let _ = writeln!(out, "CREATE TABLE {full} (");
    let cols: Vec<String> = t
        .columns
        .iter()
        .map(|c| {
            let mut s = format!("  `{}` {}", c.name, write_type(&c.data_type));
            if !c.nullable {
                s.push_str(" NOT NULL");
            }
            if let Some(comment) = &c.comment {
                let _ = write!(s, " COMMENT {}", quote(comment));
            }
            s
        })
        .collect();
    out.push_str(&cols.join(",\n"));
    out.push_str("\n)\nUSING iceberg");
    let col_name =
        |id: &Id| t.columns.iter().find(|c| &c.id == id).map(|c| format!("`{}`", c.name)).unwrap_or_default();
    let ice = t.options.iceberg.clone().unwrap_or_default();
    if !ice.partition_spec.is_empty() {
        let items: Vec<String> =
            ice.partition_spec.iter().map(|p| transform(&p.transform, &col_name(&p.source))).collect();
        let _ = write!(out, "\nPARTITIONED BY ({})", items.join(", "));
    }
    if let Some(location) = &ice.location {
        let _ = write!(out, "\nLOCATION {}", quote(location));
    }
    if let Some(comment) = &t.comment {
        let _ = write!(out, "\nCOMMENT {}", quote(comment));
    }
    let mut props: Vec<(String, String)> = Vec::new();
    if let Some(v) = ice.format_version {
        props.push(("format-version".to_string(), v.to_string()));
    }
    props.extend(ice.properties.iter().map(|(k, v)| (k.clone(), v.clone())));
    if !props.is_empty() {
        let lines: Vec<String> = props.iter().map(|(k, v)| format!("  {} = {}", quote(k), quote(v))).collect();
        let _ = write!(out, "\nTBLPROPERTIES (\n{}\n)", lines.join(",\n"));
    }
    out.push_str(";\n");
    if !ice.sort_order.is_empty() {
        let items: Vec<String> = ice
            .sort_order
            .iter()
            .map(|s| {
                let dir = if s.direction == Direction::Asc { "ASC" } else { "DESC" };
                let default_nulls = if s.direction == Direction::Asc { Nulls::First } else { Nulls::Last };
                let nulls = if s.nulls == default_nulls {
                    String::new()
                } else if s.nulls == Nulls::First {
                    " NULLS FIRST".to_string()
                } else {
                    " NULLS LAST".to_string()
                };
                format!("{} {dir}{nulls}", transform(&s.transform, &col_name(&s.source)))
            })
            .collect();
        let _ = writeln!(out, "ALTER TABLE {full} WRITE ORDERED BY ({});", items.join(", "));
    }
    if !ice.identifier_fields.is_empty() {
        let fields: Vec<String> = ice.identifier_fields.iter().map(col_name).collect();
        let _ = writeln!(out, "ALTER TABLE {full} SET IDENTIFIER FIELDS {};", fields.join(", "));
    }
    let _ = schema;
    out.push('\n');
    out
}

fn view(paths: &HashMap<Id, Vec<String>>, v: &View) -> String {
    let mut out = String::new();
    notes(v.notes.as_ref(), &mut out);
    let _ = write!(out, "CREATE VIEW {}", name(paths, &v.namespace, &v.name));
    if let Some(comment) = &v.comment {
        let _ = write!(out, "\nCOMMENT {}", quote(comment));
    }
    let _ = writeln!(out, " AS\n{};\n", v.definition);
    out
}

/// `identity` → the column; `day` → `day(col)`; `bucket[16]` → `bucket(16, col)`.
fn transform(t: &str, col: &str) -> String {
    if t == "identity" {
        return col.to_string();
    }
    if let Some((name, n)) = t.strip_suffix(']').and_then(|s| s.split_once('[')) {
        return format!("{name}({n}, {col})");
    }
    format!("{t}({col})")
}
