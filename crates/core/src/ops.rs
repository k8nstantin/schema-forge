//! Operations: every change to a schema is one (docs/model.md, Operations). An operation names what it changes the
//! way the agent writes it (`orders`, `shop.orders`, `orders.total`, or an id), resolved against the schema as it is
//! when the operation applies, so one batch can add a table and then relate it. Each is checked against the model's
//! own rules; a destructive one says what it would break and needs a yes.

use serde::{Deserialize, Serialize};

use crate::{
    Column, DataType, Ends, IcebergTable, Id, Kind, Namespace, PartitionField, PrimaryKey, Relationship, Schema, Table,
    Target,
};

/// A column as an operation gives it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NewColumn {
    pub name: String,
    #[serde(rename = "type")]
    pub data_type: DataType,
    #[serde(default = "yes")]
    pub nullable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
}

const fn yes() -> bool {
    true
}

/// A partition field as an operation gives it: a column and a transform.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NewPartition {
    pub column: String,
    pub transform: String,
}

/// One change.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Op {
    AddNamespace {
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        parent: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        comment: Option<String>,
    },
    RenameNamespace {
        namespace: String,
        name: String,
    },
    DropNamespace {
        namespace: String,
    },
    AddTable {
        namespace: String,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        comment: Option<String>,
        columns: Vec<NewColumn>,
        /// Its key, by column name.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        primary_key: Vec<String>,
    },
    RenameTable {
        table: String,
        name: String,
    },
    DropTable {
        table: String,
    },
    SetTableComment {
        table: String,
        #[serde(default)]
        comment: Option<String>,
    },
    AddColumn {
        table: String,
        column: NewColumn,
        /// After this column; at the end when left out.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        after: Option<String>,
    },
    RenameColumn {
        column: String,
        name: String,
    },
    AlterColumn {
        column: String,
        #[serde(default, rename = "type", skip_serializing_if = "Option::is_none")]
        data_type: Option<DataType>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        nullable: Option<bool>,
        /// A new default; an empty one takes it away.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        default: Option<String>,
        /// A new description; an empty one takes it away.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        comment: Option<String>,
    },
    DropColumn {
        column: String,
    },
    SetPrimaryKey {
        table: String,
        columns: Vec<String>,
    },
    /// Iceberg: the columns that identify a row (upserts, merge-on-read deletes).
    SetIdentifierFields {
        table: String,
        columns: Vec<String>,
    },
    /// A relationship: `from`'s columns point at `to`'s key. On Iceberg it is logical, never enforced.
    Relate {
        from: String,
        columns: Vec<String>,
        to: String,
        to_columns: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    Unrelate {
        relationship: String,
    },
    /// MySQL, PostgreSQL: an index on columns, in order.
    AddIndex {
        table: String,
        columns: Vec<String>,
        #[serde(default)]
        unique: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    DropIndex {
        table: String,
        index: String,
    },
    /// Iceberg: the partition spec, replacing the one there is.
    SetPartitionSpec {
        table: String,
        fields: Vec<NewPartition>,
    },
    /// Iceberg: a table property (`write.delete.mode` = `merge-on-read`).
    SetProperty {
        table: String,
        key: String,
        value: String,
    },
    UnsetProperty {
        table: String,
        key: String,
    },
}

/// What an operation did, in words, and whether it was destructive (and so needed a yes).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Done {
    pub summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructive: Option<String>,
}

/// Applies `op` to `schema`. A destructive operation is refused unless `confirmed`, and its refusal says what it
/// would break. The result keeps every one of the model's own rules the schema kept before.
///
/// # Errors
/// Why it cannot apply, in a sentence the agent can act on.
pub fn apply(schema: &mut Schema, op: &Op, confirmed: bool) -> Result<Done, String> {
    let before = crate::check(schema);
    let mut next = schema.clone();
    let mut done = change(&mut next, op)?;
    if let Some(what) = &done.destructive
        && !confirmed
    {
        return Err(format!("destructive, so not done without a yes: it would have {} ({what})", done.summary));
    }
    let after = crate::check(&next);
    let new: Vec<String> = after.iter().filter(|p| !before.contains(p)).map(ToString::to_string).collect();
    if !new.is_empty() {
        return Err(format!("{} breaks the model's rules: {}", done.summary, new.join("; ")));
    }
    *schema = next;
    done.summary = done.summary.trim().to_string();
    Ok(done)
}

fn change(s: &mut Schema, op: &Op) -> Result<Done, String> {
    let ok = |summary: String| Ok(Done { summary, destructive: None });
    match op {
        Op::AddNamespace { name, parent, comment } => {
            let parent = parent.as_deref().map(|p| namespace(s, p)).transpose()?;
            if s.namespaces.iter().any(|n| n.name == *name && n.parent == parent) {
                return Err(format!("namespace `{name}` is already there"));
            }
            let id = fresh(s, Id::from_name(Kind::Namespace, &[name]));
            s.namespaces.push(Namespace { id, name: name.clone(), parent, comment: comment.clone() });
            ok(format!("added namespace `{name}`"))
        }
        Op::RenameNamespace { namespace: n, name } => {
            let id = namespace(s, n)?;
            let ns = s.namespaces.iter_mut().find(|x| x.id == id).expect("found");
            let old = std::mem::replace(&mut ns.name, name.clone());
            ok(format!("renamed namespace `{old}` to `{name}`"))
        }
        Op::DropNamespace { namespace: n } => {
            let id = namespace(s, n)?;
            if s.tables.iter().any(|t| t.namespace == id)
                || s.views.iter().any(|v| v.namespace == id)
                || s.namespaces.iter().any(|x| x.parent.as_ref() == Some(&id))
            {
                return Err(format!("namespace `{n}` is not empty: drop what is in it first"));
            }
            s.namespaces.retain(|x| x.id != id);
            Ok(Done { summary: format!("dropped namespace `{n}`"), destructive: Some("it goes".to_string()) })
        }
        Op::AddTable { namespace: n, name, comment, columns, primary_key } => {
            let ns = namespace(s, n)?;
            if s.tables.iter().any(|t| t.namespace == ns && t.name == *name)
                || s.views.iter().any(|v| v.namespace == ns && v.name == *name)
            {
                return Err(format!("`{name}` is already in `{n}`"));
            }
            let id = fresh(s, Id::from_name(Kind::Table, &[name]));
            let mut t = Table {
                id: id.clone(),
                namespace: ns,
                name: name.clone(),
                comment: comment.clone(),
                notes: None,
                tags: Vec::new(),
                area: None,
                columns: Vec::new(),
                primary_key: None,
                uniques: Vec::new(),
                checks: Vec::new(),
                indexes: Vec::new(),
                patterns: std::collections::BTreeMap::new(),
                partition_of: None,
                options: crate::TableOptions::default(),
            };
            if s.target == Target::Iceberg {
                t.options.iceberg = Some(IcebergTable::default());
            }
            for c in columns {
                let cid = column_id(s, &t, &c.name);
                push_column(s.target, &mut t, c, None, cid)?;
            }
            if !primary_key.is_empty() {
                let cols = primary_key.iter().map(|c| column_in(&t, c)).collect::<Result<Vec<_>, _>>()?;
                set_key(s.target, &mut t, cols);
            }
            s.tables.push(t);
            ok(format!("added table `{name}` with {} columns", columns.len()))
        }
        Op::RenameTable { table, name } => {
            let i = table_at(s, table)?;
            let ns = s.tables[i].namespace.clone();
            if s.tables.iter().any(|t| t.namespace == ns && t.name == *name) {
                return Err(format!("`{name}` is already in its namespace"));
            }
            let old = std::mem::replace(&mut s.tables[i].name, name.clone());
            ok(format!("renamed table `{old}` to `{name}`"))
        }
        Op::DropTable { table } => {
            let i = table_at(s, table)?;
            let id = s.tables[i].id.clone();
            let mut breaks = Vec::new();
            let rels: Vec<&Relationship> =
                s.relationships.iter().filter(|r| r.from.table == id || r.to.table == id).collect();
            if !rels.is_empty() {
                breaks.push(format!("{} relationships go with it", rels.len()));
            }
            let views: Vec<String> =
                s.views.iter().filter(|v| v.reads.contains(&id)).map(|v| format!("`{}`", v.name)).collect();
            if !views.is_empty() {
                return Err(format!("views read `{table}`: {}; change them first", views.join(", ")));
            }
            let name = s.tables.remove(i).name;
            s.relationships.retain(|r| r.from.table != id && r.to.table != id);
            breaks.insert(0, "the table and its data go".to_string());
            Ok(Done { summary: format!("dropped table `{name}`"), destructive: Some(breaks.join(", ")) })
        }
        Op::SetTableComment { table, comment } => {
            let i = table_at(s, table)?;
            s.tables[i].comment = comment.clone().filter(|c| !c.trim().is_empty());
            ok(format!("described table `{}`", s.tables[i].name))
        }
        Op::AddColumn { table, column, after } => {
            let i = table_at(s, table)?;
            let target = s.target;
            let at = match after {
                Some(a) => Some(
                    column_in(&s.tables[i], a)
                        .map(|id| s.tables[i].columns.iter().position(|c| c.id == id).expect("found") + 1)?,
                ),
                None => None,
            };
            let cid = column_id(s, &s.tables[i], &column.name);
            push_column(target, &mut s.tables[i], column, at, cid)?;
            let destructive = (!column.nullable && column.default.is_none())
                .then(|| "a required column with no default: existing rows have no value for it".to_string());
            Ok(Done { summary: format!("added column `{}.{}`", s.tables[i].name, column.name), destructive })
        }
        Op::RenameColumn { column, name } => {
            let (i, c) = column_at(s, column)?;
            let t = &mut s.tables[i];
            if t.columns.iter().any(|x| x.name == *name) {
                return Err(format!("`{}` already has a column `{name}`", t.name));
            }
            let old = std::mem::replace(&mut t.columns[c].name, name.clone());
            ok(format!("renamed column `{}.{old}` to `{name}`", t.name))
        }
        Op::AlterColumn { column, data_type, nullable, default, comment } => {
            let (i, c) = column_at(s, column)?;
            let target = s.target;
            let table = s.tables[i].name.clone();
            let col = &mut s.tables[i].columns[c];
            let mut what = Vec::new();
            let mut destructive = Vec::new();
            if let Some(t) = data_type
                && *t != col.data_type
            {
                if !widens(target, &col.data_type, t) {
                    destructive.push(format!("{} to {} may not hold every value", col.data_type.name, t.name));
                }
                let mut t = t.clone();
                if target == Target::Iceberg {
                    // Fields there before keep their ids, so the data written under them still reads.
                    let mut next = next_field_id(&s.tables[i]);
                    keep_field_ids(&s.tables[i].columns[c].data_type, &mut t, &mut next);
                    gave_out(&mut s.tables[i], next);
                }
                let col = &mut s.tables[i].columns[c];
                col.data_type = t;
                what.push("its type");
            }
            let col = &mut s.tables[i].columns[c];
            if let Some(n) = nullable
                && *n != col.nullable
            {
                if !n {
                    destructive.push("required: existing empty values break it".to_string());
                }
                col.nullable = *n;
                what.push(if *n { "may be empty" } else { "required" });
            }
            if let Some(d) = default {
                col.default = Some(d.clone()).filter(|d| !d.trim().is_empty());
                what.push("its default");
            }
            if let Some(cm) = comment {
                col.comment = Some(cm.clone()).filter(|c| !c.trim().is_empty());
                what.push("its description");
            }
            if what.is_empty() {
                return Err(format!("nothing to change on `{column}`"));
            }
            Ok(Done {
                summary: format!("changed `{table}.{}`: {}", col.name, what.join(", ")),
                destructive: (!destructive.is_empty()).then(|| destructive.join("; ")),
            })
        }
        Op::DropColumn { column } => {
            let (i, c) = column_at(s, column)?;
            let id = s.tables[i].columns[c].id.clone();
            let t = &s.tables[i];
            if t.primary_key.as_ref().is_some_and(|k| k.columns.contains(&id))
                || t.options.iceberg.as_ref().is_some_and(|ice| ice.identifier_fields.contains(&id))
            {
                return Err(format!("`{column}` is in the key: change the key first"));
            }
            if s.relationships.iter().any(|r| r.from.columns.contains(&id) || r.to.columns.contains(&id)) {
                return Err(format!("a relationship uses `{column}`: take it away first"));
            }
            if t.options.iceberg.as_ref().is_some_and(|ice| {
                ice.partition_spec.iter().any(|p| p.source == id) || ice.sort_order.iter().any(|p| p.source == id)
            }) {
                return Err(format!("`{column}` partitions or sorts the table: change that first"));
            }
            let t = &mut s.tables[i];
            let name = t.columns.remove(c).name;
            t.indexes.retain(|ix| !ix.parts.iter().any(|p| p.column.as_ref() == Some(&id)));
            t.uniques.retain(|u| !u.columns.contains(&id));
            Ok(Done {
                summary: format!("dropped column `{}.{name}`", t.name),
                destructive: Some("the column and its values go".to_string()),
            })
        }
        Op::SetPrimaryKey { table, columns } => {
            let i = table_at(s, table)?;
            let target = s.target;
            let t = &mut s.tables[i];
            let cols = columns.iter().map(|c| column_in(t, c)).collect::<Result<Vec<_>, _>>()?;
            let had = t.primary_key.is_some()
                || t.options.iceberg.as_ref().is_some_and(|ice| !ice.identifier_fields.is_empty());
            let mut why = Vec::new();
            if had {
                why.push("it replaces the key there is".to_string());
            }
            why.extend(made_required(t, &cols));
            set_key(target, t, cols);
            Ok(Done {
                summary: format!("keyed `{}` by {}", t.name, columns.join(", ")),
                destructive: (!why.is_empty()).then(|| why.join("; ")),
            })
        }
        Op::SetIdentifierFields { table, columns } => {
            iceberg_only(s.target)?;
            let i = table_at(s, table)?;
            let t = &mut s.tables[i];
            let cols = columns.iter().map(|c| column_in(t, c)).collect::<Result<Vec<_>, _>>()?;
            // Like a key: identifier fields are required, and replacing them, or making a column required, is
            // destructive.
            let mut why = Vec::new();
            if t.options.iceberg.as_ref().is_some_and(|ice| !ice.identifier_fields.is_empty()) {
                why.push("it replaces the identifier fields there are".to_string());
            }
            why.extend(made_required(t, &cols));
            set_key(Target::Iceberg, t, cols);
            Ok(Done {
                summary: format!("`{}` is identified by {}", t.name, columns.join(", ")),
                destructive: (!why.is_empty()).then(|| why.join("; ")),
            })
        }
        Op::Relate { from, columns, to, to_columns, name } => {
            let (fi, ti) = (table_at(s, from)?, table_at(s, to)?);
            if columns.len() != to_columns.len() || columns.is_empty() {
                return Err("a relationship joins as many columns on each side, at least one".to_string());
            }
            let fc = columns.iter().map(|c| column_in(&s.tables[fi], c)).collect::<Result<Vec<_>, _>>()?;
            let tc = to_columns.iter().map(|c| column_in(&s.tables[ti], c)).collect::<Result<Vec<_>, _>>()?;
            let (fname, tname) = (s.tables[fi].name.clone(), s.tables[ti].name.clone());
            let id = fresh(s, Id::from_name(Kind::Relationship, &[&fname, &tname]));
            s.relationships.push(Relationship {
                id,
                name: name.clone(),
                from: Ends { table: s.tables[fi].id.clone(), columns: fc },
                to: Ends { table: s.tables[ti].id.clone(), columns: tc },
                enforced: s.target != Target::Iceberg,
                on_delete: None,
                on_update: None,
                deferrable: None,
                match_kind: None,
            });
            ok(format!("related `{fname}` ({}) to `{tname}` ({})", columns.join(", "), to_columns.join(", ")))
        }
        Op::Unrelate { relationship } => {
            let before = s.relationships.len();
            s.relationships.retain(|r| r.id.as_str() != relationship && r.name.as_deref() != Some(relationship));
            if s.relationships.len() == before {
                return Err(format!("there is no relationship `{relationship}`"));
            }
            Ok(Done {
                summary: format!("took away relationship `{relationship}`"),
                destructive: Some("the link between the tables goes".to_string()),
            })
        }
        Op::AddIndex { table, columns, unique, name } => {
            if s.target == Target::Iceberg {
                return Err("Iceberg tables have no indexes: partition or sort them instead".to_string());
            }
            let i = table_at(s, table)?;
            let t = &s.tables[i];
            let cols = columns.iter().map(|c| column_in(t, c)).collect::<Result<Vec<_>, _>>()?;
            if cols.is_empty() {
                return Err("an index needs at least one column".to_string());
            }
            let name = name.clone().unwrap_or_else(|| format!("ix_{}_{}", t.name, columns.join("_")));
            if s.tables.iter().any(|x| x.indexes.iter().any(|ix| ix.name == name)) {
                return Err(format!("an index `{name}` is already there"));
            }
            let id = fresh(s, Id::from_name(Kind::Index, &[&t.name, &columns.join("_")]));
            let t = &mut s.tables[i];
            t.indexes.push(crate::Index {
                id,
                name: name.clone(),
                unique: *unique,
                parts: cols
                    .into_iter()
                    .map(|c| crate::IndexPart {
                        column: Some(c),
                        expression: None,
                        direction: None,
                        nulls: None,
                        length: None,
                    })
                    .collect(),
                method: None,
                include: Vec::new(),
                predicate: None,
            });
            ok(format!("indexed `{}` on {}{}", t.name, columns.join(", "), if *unique { ", unique" } else { "" }))
        }
        Op::DropIndex { table, index } => {
            let i = table_at(s, table)?;
            let t = &mut s.tables[i];
            let before = t.indexes.len();
            t.indexes.retain(|ix| ix.name != *index && ix.id.as_str() != index);
            if t.indexes.len() == before {
                return Err(format!("`{}` has no index `{index}`", t.name));
            }
            Ok(Done {
                summary: format!("dropped index `{index}` on `{}`", t.name),
                destructive: Some("reads that used it get slower".to_string()),
            })
        }
        Op::SetPartitionSpec { table, fields } => {
            iceberg_only(s.target)?;
            let i = table_at(s, table)?;
            let t = &mut s.tables[i];
            let mut spec = Vec::new();
            for f in fields {
                spec.push(PartitionField {
                    source: column_in(t, &f.column)?,
                    transform: f.transform.clone(),
                    name: None,
                });
            }
            let had = t.options.iceberg.as_ref().is_some_and(|ice| !ice.partition_spec.is_empty());
            t.options.iceberg.get_or_insert_with(IcebergTable::default).partition_spec = spec;
            let how: Vec<String> = fields.iter().map(|f| format!("{}({})", f.transform, f.column)).collect();
            Ok(Done {
                summary: format!("partitioned `{}` by {}", t.name, how.join(", ")),
                destructive: had.then(|| "it replaces the partition spec there is".to_string()),
            })
        }
        Op::SetProperty { table, key, value } => {
            iceberg_only(s.target)?;
            let i = table_at(s, table)?;
            let t = &mut s.tables[i];
            t.options.iceberg.get_or_insert_with(IcebergTable::default).properties.insert(key.clone(), value.clone());
            ok(format!("set `{key}` = `{value}` on `{}`", t.name))
        }
        Op::UnsetProperty { table, key } => {
            iceberg_only(s.target)?;
            let i = table_at(s, table)?;
            let t = &mut s.tables[i];
            let gone = t.options.iceberg.as_mut().and_then(|ice| ice.properties.remove(key));
            if gone.is_none() {
                return Err(format!("`{}` has no property `{key}`", t.name));
            }
            ok(format!("unset `{key}` on `{}`", t.name))
        }
    }
}

fn iceberg_only(target: Target) -> Result<(), String> {
    if target == Target::Iceberg { Ok(()) } else { Err("that is an Iceberg setting".to_string()) }
}

/// `id`, or the first numbered one free (`t_orders_2`).
fn fresh(s: &Schema, id: Id) -> Id {
    fresh_beside(s, id, |_| false)
}

/// `id`, or the first numbered one free in the schema and not `also` taken: ids are unique across the schema.
fn fresh_beside(s: &Schema, id: Id, also: impl Fn(&Id) -> bool) -> Id {
    let taken = |x: &Id| {
        also(x)
            || s.namespaces.iter().any(|n| &n.id == x)
            || s.tables
                .iter()
                .any(|t| &t.id == x || t.columns.iter().any(|c| &c.id == x) || t.indexes.iter().any(|ix| &ix.id == x))
            || s.views.iter().any(|v| &v.id == x)
            || s.relationships.iter().any(|r| &r.id == x)
    };
    if !taken(&id) {
        return id;
    }
    (2..).map(|n| id.numbered(n)).find(|x| !taken(x)).expect("a free id")
}

/// A namespace by name, dotted path or id.
fn namespace(s: &Schema, text: &str) -> Result<Id, String> {
    let path = |id: &Id| {
        let mut names = Vec::new();
        let mut at = Some(id);
        while let Some(i) = at {
            let Some(n) = s.namespaces.iter().find(|n| &n.id == i) else { break };
            names.push(n.name.as_str());
            at = n.parent.as_ref();
            if names.len() > s.namespaces.len() {
                break;
            }
        }
        names.reverse();
        names.join(".")
    };
    let hits: Vec<&Namespace> =
        s.namespaces.iter().filter(|n| n.name == text || n.id.as_str() == text || path(&n.id) == text).collect();
    match hits.as_slice() {
        [one] => Ok(one.id.clone()),
        [] => Err(format!("there is no namespace `{text}`")),
        _ => Err(format!("`{text}` names more than one namespace: give its path")),
    }
}

/// A table by name, `namespace.name` or id: its place in the schema.
fn table_at(s: &Schema, text: &str) -> Result<usize, String> {
    let hits: Vec<usize> = s
        .tables
        .iter()
        .enumerate()
        .filter(|(_, t)| {
            t.name == text
                || t.id.as_str() == text
                || text
                    .rsplit_once('.')
                    .is_some_and(|(ns, name)| name == t.name && namespace(s, ns).is_ok_and(|n| n == t.namespace))
        })
        .map(|(i, _)| i)
        .collect();
    match hits.as_slice() {
        [one] => Ok(*one),
        [] => Err(format!("there is no table `{text}`")),
        _ => Err(format!("`{text}` is in more than one namespace: write `namespace.{text}`")),
    }
}

/// A column by `table.column` (the table as `table_at` reads it) or id.
fn column_at(s: &Schema, text: &str) -> Result<(usize, usize), String> {
    for (i, t) in s.tables.iter().enumerate() {
        if let Some(c) = t.columns.iter().position(|c| c.id.as_str() == text) {
            return Ok((i, c));
        }
    }
    let (table, column) =
        text.rsplit_once('.').ok_or_else(|| format!("write a column as `table.column`, not `{text}`"))?;
    let i = table_at(s, table)?;
    let c = s.tables[i]
        .columns
        .iter()
        .position(|c| c.name == column)
        .ok_or_else(|| format!("`{table}` has no column `{column}`"))?;
    Ok((i, c))
}

/// A column of `t` by name or id.
fn column_in(t: &Table, text: &str) -> Result<Id, String> {
    t.columns
        .iter()
        .find(|c| c.name == text || c.id.as_str() == text)
        .map(|c| c.id.clone())
        .ok_or_else(|| format!("`{}` has no column `{text}`", t.name))
}

/// What making `cols` a key does to columns that may be empty: they become required.
fn made_required(t: &Table, cols: &[Id]) -> Option<String> {
    let names: Vec<&str> =
        t.columns.iter().filter(|c| cols.contains(&c.id) && c.nullable).map(|c| c.name.as_str()).collect();
    (!names.is_empty()).then(|| format!("{} become required: existing empty values break it", names.join(", ")))
}

fn set_key(target: Target, t: &mut Table, cols: Vec<Id>) {
    for c in t.columns.iter_mut().filter(|c| cols.contains(&c.id)) {
        c.nullable = false;
    }
    if target == Target::Iceberg {
        t.options.iceberg.get_or_insert_with(IcebergTable::default).identifier_fields = cols;
    } else {
        t.primary_key = Some(PrimaryKey { name: None, columns: cols });
    }
}

/// Gives `new` the field ids of `old` wherever a field, element, key or value is the same one (by name, or by
/// place for a list's element and a map's key and value); what is new gets the next ids.
fn keep_field_ids(old: &DataType, new: &mut DataType, next: &mut i32) {
    match (old.name.as_str(), new.name.as_str()) {
        ("struct", "struct") => {
            let mut fresh_fields = Vec::new();
            for (i, f) in new.fields.iter_mut().enumerate() {
                if let Some(o) = old.fields.iter().find(|o| o.name == f.name) {
                    f.field_id = o.field_id;
                    keep_field_ids(&o.data_type, &mut f.data_type, next);
                } else {
                    f.field_id = *next;
                    *next += 1;
                    fresh_fields.push(i);
                }
            }
            for i in fresh_fields {
                new.fields[i].data_type.assign_field_ids(next);
            }
        }
        ("list", "list") => {
            new.element_id = old.element_id;
            if let (Some(o), Some(n)) = (old.of.as_deref(), new.of.as_deref_mut()) {
                keep_field_ids(o, n, next);
            }
        }
        ("map", "map") => {
            new.key_id = old.key_id;
            new.element_id = old.element_id;
            if let (Some(o), Some(n)) = (old.key.as_deref(), new.key.as_deref_mut()) {
                keep_field_ids(o, n, next);
            }
            if let (Some(o), Some(n)) = (old.of.as_deref(), new.of.as_deref_mut()) {
                keep_field_ids(o, n, next);
            }
        }
        _ => new.assign_field_ids(next),
    }
}

fn max_field_id(t: &Table) -> i32 {
    fn walk(d: &DataType, m: &mut i32) {
        for x in [d.element_id, d.key_id].into_iter().flatten() {
            *m = (*m).max(x);
        }
        for f in &d.fields {
            *m = (*m).max(f.field_id);
            walk(&f.data_type, m);
        }
        for x in [d.of.as_deref(), d.key.as_deref()].into_iter().flatten() {
            walk(x, m);
        }
    }
    let mut m = 0;
    for c in &t.columns {
        m = m.max(c.field_id.unwrap_or(0));
        walk(&c.data_type, &mut m);
    }
    m
}

/// The next field id an Iceberg table gives out: past every id it holds and every id it ever gave out.
fn next_field_id(t: &Table) -> i32 {
    let last = t.options.iceberg.as_ref().and_then(|i| i.last_column_id).unwrap_or(0);
    max_field_id(t).max(last) + 1
}

/// Records that `t` gave out every field id below `next`.
fn gave_out(t: &mut Table, next: i32) {
    let ice = t.options.iceberg.get_or_insert_with(IcebergTable::default);
    ice.last_column_id = Some(ice.last_column_id.unwrap_or(0).max(next - 1));
}

/// A column id free across the schema, and in `t`, which may not be in the schema yet.
fn column_id(s: &Schema, t: &Table, name: &str) -> Id {
    fresh_beside(s, Id::from_name(Kind::Column, &[&t.name, name]), |x| t.columns.iter().any(|c| &c.id == x))
}

fn push_column(target: Target, t: &mut Table, c: &NewColumn, at: Option<usize>, id: Id) -> Result<(), String> {
    if t.columns.iter().any(|x| x.name == c.name) {
        return Err(format!("`{}` already has a column `{}`", t.name, c.name));
    }
    let mut data_type = c.data_type.clone();
    let mut field_id = None;
    if target == Target::Iceberg {
        let mut next = next_field_id(t);
        field_id = Some(next);
        next += 1;
        data_type.assign_field_ids(&mut next);
        gave_out(t, next);
    }
    let column = Column {
        id,
        name: c.name.clone(),
        data_type,
        nullable: c.nullable,
        default: c.default.clone(),
        initial_default: None,
        write_default: None,
        generated: None,
        identity: None,
        collation: None,
        comment: c.comment.clone(),
        field_id,
        on_update: None,
    };
    match at {
        Some(i) => t.columns.insert(i, column),
        None => t.columns.push(column),
    }
    Ok(())
}

/// Whether every value of `from` fits `to`: the safe promotions (Iceberg's int to long, float to double, a wider
/// decimal; a longer varchar).
fn widens(target: Target, from: &DataType, to: &DataType) -> bool {
    let wider = |a: Option<u32>, b: Option<u32>| matches!((a, b), (Some(a), Some(b)) if b >= a) || b.is_none();
    match (from.name.as_str(), to.name.as_str()) {
        ("int", "long") | ("float", "double") if target == Target::Iceberg => true,
        ("smallint", "integer" | "bigint") | ("integer", "bigint") | ("real", "double precision") => true,
        ("decimal", "decimal") | ("numeric", "numeric") => {
            from.scale == to.scale
                && match (from.precision, to.precision) {
                    (Some(a), Some(b)) => b >= a,
                    (_, None) => target == Target::Postgres,
                    (None, Some(_)) => false,
                }
        }
        ("varchar", "varchar" | "text") | ("char", "varchar" | "text") => {
            to.name == "text" || wider(from.length, to.length)
        }
        // Iceberg evolves a struct safely when every field stays (each the same or wider) and new ones may be
        // empty; a list's element or a map's value may widen too.
        ("struct", "struct") if target == Target::Iceberg => {
            from.fields.iter().all(|f| {
                to.fields.iter().any(|t| {
                    t.name == f.name && (t.data_type == f.data_type || widens(target, &f.data_type, &t.data_type))
                })
            }) && to.fields.iter().filter(|t| !from.fields.iter().any(|f| f.name == t.name)).all(|t| t.nullable)
        }
        ("list", "list") | ("map", "map") if target == Target::Iceberg => {
            from.key == to.key
                && match (from.of.as_deref(), to.of.as_deref()) {
                    (Some(a), Some(b)) => a == b || widens(target, a, b),
                    _ => false,
                }
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn col(name: &str, ty: &str) -> NewColumn {
        NewColumn { name: name.into(), data_type: DataType::named(ty), nullable: true, default: None, comment: None }
    }

    fn lake() -> Schema {
        let mut s = Schema::new(Target::Iceberg);
        apply(&mut s, &Op::AddNamespace { name: "shop".into(), parent: None, comment: None }, false)
            .expect("namespace");
        s
    }

    #[test]
    fn a_batch_builds_and_names_resolve_as_it_goes() {
        let mut s = lake();
        let add = |name: &str, cols: Vec<NewColumn>, key: &[&str]| Op::AddTable {
            namespace: "shop".into(),
            name: name.into(),
            comment: None,
            columns: cols,
            primary_key: key.iter().map(|k| (*k).to_string()).collect(),
        };
        apply(&mut s, &add("customers", vec![col("id", "string")], &["id"]), false).expect("customers");
        apply(&mut s, &add("orders", vec![col("id", "string"), col("customer_id", "string")], &["id"]), false)
            .expect("orders");
        let rel = Op::Relate {
            from: "orders".into(),
            columns: vec!["customer_id".into()],
            to: "shop.customers".into(),
            to_columns: vec!["id".into()],
            name: None,
        };
        assert_eq!(
            apply(&mut s, &rel, false).expect("relate").summary,
            "related `orders` (customer_id) to `customers` (id)"
        );
        let orders = s.tables.iter().find(|t| t.name == "orders").expect("orders");
        assert_eq!(
            orders.options.iceberg.as_ref().map(|i| i.identifier_fields.len()),
            Some(1),
            "an Iceberg key is identifier fields"
        );
        assert!(!orders.columns[0].nullable, "a key column is required");
        assert_eq!(orders.columns.iter().map(|c| c.field_id).collect::<Vec<_>>(), [Some(1), Some(2)]);
        assert!(!s.relationships[0].enforced, "logical on Iceberg");
        let mut list = DataType::named("list");
        list.of = Some(Box::new(DataType::named("string")));
        apply(
            &mut s,
            &Op::AddColumn {
                table: "orders".into(),
                column: NewColumn { data_type: list, ..col("tags", "") },
                after: Some("id".into()),
            },
            false,
        )
        .expect("tags");
        let orders = s.tables.iter().find(|t| t.name == "orders").expect("orders");
        assert_eq!(orders.columns[1].name, "tags");
        assert_eq!((orders.columns[1].field_id, orders.columns[1].data_type.element_id), (Some(3), Some(4)));
    }

    #[test]
    fn what_is_wrong_or_destructive_is_refused() {
        let mut s = lake();
        let t = Op::AddTable {
            namespace: "shop".into(),
            name: "orders".into(),
            comment: None,
            columns: vec![col("id", "string"), col("total", "int")],
            primary_key: vec![],
        };
        apply(&mut s, &t, false).expect("orders");
        assert!(apply(&mut s, &t, false).unwrap_err().contains("already"), "names are unique");
        assert!(apply(&mut s, &Op::DropTable { table: "nope".into() }, true).unwrap_err().contains("no table"));
        let drop = Op::DropColumn { column: "orders.total".into() };
        assert!(apply(&mut s, &drop, false).unwrap_err().contains("destructive"), "a drop needs a yes");
        let widen = Op::AlterColumn {
            column: "orders.total".into(),
            data_type: Some(DataType::named("long")),
            nullable: None,
            default: None,
            comment: None,
        };
        apply(&mut s, &widen, false).expect("int to long is safe on Iceberg");
        let narrow = Op::AlterColumn {
            column: "orders.total".into(),
            data_type: Some(DataType::named("int")),
            nullable: None,
            default: None,
            comment: None,
        };
        assert!(apply(&mut s, &narrow, false).unwrap_err().contains("destructive"));
        apply(&mut s, &drop, true).expect("with a yes");
        assert!(
            apply(&mut s, &Op::SetProperty { table: "orders".into(), key: "k".into(), value: "v".into() }, false)
                .is_ok()
        );
        let mut pg = Schema::new(Target::Postgres);
        assert!(
            apply(&mut pg, &Op::AddNamespace { name: "public".into(), parent: None, comment: None }, false).is_ok()
        );
        assert!(
            apply(&mut pg, &Op::SetIdentifierFields { table: "x".into(), columns: vec![] }, false)
                .unwrap_err()
                .contains("Iceberg")
        );
    }

    #[test]
    fn iceberg_field_ids_are_never_given_out_twice_and_nested_ones_stay() {
        let mut s = lake();
        let table = Op::AddTable {
            namespace: "shop".into(),
            name: "orders".into(),
            comment: None,
            columns: vec![col("id", "string"), col("total", "long")],
            primary_key: vec![],
        };
        apply(&mut s, &table, false).expect("orders");
        apply(&mut s, &Op::DropColumn { column: "orders.total".into() }, true).expect("dropped");
        apply(&mut s, &Op::AddColumn { table: "orders".into(), column: col("note", "string"), after: None }, false)
            .expect("note");
        let ids: Vec<Option<i32>> = s.tables[0].columns.iter().map(|c| c.field_id).collect();
        assert_eq!(ids, [Some(1), Some(3)], "total's id 2 is not given to note");
        // A struct grows a field: the fields there keep their ids.
        let addr = crate::DataType {
            fields: vec![
                crate::StructField {
                    field_id: 0,
                    name: "street".into(),
                    nullable: true,
                    data_type: DataType::named("string"),
                    comment: None,
                },
                crate::StructField {
                    field_id: 0,
                    name: "city".into(),
                    nullable: true,
                    data_type: DataType::named("string"),
                    comment: None,
                },
            ],
            ..DataType::named("struct")
        };
        let add = |ty: DataType| Op::AddColumn {
            table: "orders".into(),
            column: NewColumn { name: "addr".into(), data_type: ty, nullable: true, default: None, comment: None },
            after: None,
        };
        apply(&mut s, &add(addr.clone()), false).expect("addr");
        let before: Vec<i32> = s.tables[0].columns[2].data_type.fields.iter().map(|f| f.field_id).collect();
        let mut wider = addr;
        wider.fields.push(crate::StructField {
            field_id: 0,
            name: "zip".into(),
            nullable: true,
            data_type: DataType::named("string"),
            comment: None,
        });
        let alter = Op::AlterColumn {
            column: "orders.addr".into(),
            data_type: Some(wider),
            nullable: None,
            default: None,
            comment: None,
        };
        apply(&mut s, &alter, false).expect("wider");
        let after: Vec<i32> = s.tables[0].columns[2].data_type.fields.iter().map(|f| f.field_id).collect();
        assert_eq!(after[..2], before[..], "street and city keep their ids");
        assert!(after[2] > *before.iter().max().expect("ids"), "zip gets a new one");
    }

    #[test]
    fn keys_say_when_they_make_columns_required_and_ids_stay_unique() {
        let mut s = lake();
        let t = |name: &str, cols: Vec<NewColumn>| Op::AddTable {
            namespace: "shop".into(),
            name: name.into(),
            comment: None,
            columns: cols,
            primary_key: vec![],
        };
        apply(&mut s, &t("orders", vec![col("code", "string")]), false).expect("orders");
        let key = Op::SetIdentifierFields { table: "orders".into(), columns: vec!["code".into()] };
        assert!(apply(&mut s.clone(), &key, false).is_err(), "code may be empty: making it required needs a yes");
        apply(&mut s, &key, true).expect("with a yes");
        assert!(!s.tables[0].columns[0].nullable, "an identifier field is required");
        // An id is unique across the schema: a renamed table's column id does not clash with a new table's.
        apply(&mut s, &Op::RenameTable { table: "orders".into(), name: "orders_old".into() }, false).expect("renamed");
        apply(&mut s, &t("orders", vec![col("code", "string")]), false).expect("a new orders");
        assert_ne!(s.tables[0].columns[0].id, s.tables[1].columns[0].id);
        assert!(crate::check(&s).is_empty(), "{:?}", crate::check(&s));
    }
}
