//! A schema as the rows of the cortex's tables (schema/cortex), and back; an engine's own tables declared as data, its
//! options written as their rows and read back (specs/tasks/SF-94-tables-interface.xml). Rows are plain values:
//! nothing here opens a database, the store does.
//!
//! ```
//! use schema_forge_engine::tables::{counter_id, index_id, index_part_id};
//! let index = index_id("o_orders", 1);
//! assert_eq!(index_part_id(&index, 2), "o_orders.index1.2");
//! assert_eq!(counter_id(&index), "o_orders.index");
//! ```

use std::cmp::Ordering;
use std::collections::BTreeMap;

use schema_forge_model::{Area, Column, Ends, Id, Link, Namespace, Object, Schema};

use crate::Engine;
use crate::kinds::Slot;
use crate::sections::{
    self, Action, Change, Check, ColumnSection, Deferrable, Direction, Domain, Event, Field, Generated,
    Identity as ColumnIdentity, Index, IndexPart, Kept, Key, LinkSection, Mode, Nulls, ObjectSection, OrderField,
    PartField, Partition, PartitionOf, Partitioning, Routine, SchemaSection, Sequence, Timing, Trigger,
};

// --- step 1: values and rows ---------------------------------------------------------------------------------------

/// A value of a column, as the variant of the column's type in its table file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Null,
    Bool(bool),
    /// INTEGER and BIGINT.
    Integer(i64),
    /// NUMERIC: a decimal as text (`1`, `2.5`).
    Numeric(String),
    Text(String),
    /// UUID: the 36-character form, in lowercase.
    Uuid(String),
    /// TIMESTAMPTZ: RFC 3339 in UTC, ending Z.
    Timestamp(String),
    /// JSONB: the value as serde_json writes it compactly.
    Json(String),
}

impl Value {
    /// Whether this value is of the column type `sql_type` (one of the eight a table file may use); Null is of every
    /// type.
    #[must_use]
    pub fn is_of(&self, sql_type: &str) -> bool {
        matches!(
            (self, sql_type),
            (Self::Null, _)
                | (Self::Bool(_), "BOOLEAN")
                | (Self::Integer(_), "INTEGER" | "BIGINT")
                | (Self::Numeric(_), "NUMERIC")
                | (Self::Text(_), "TEXT")
                | (Self::Uuid(_), "UUID")
                | (Self::Timestamp(_), "TIMESTAMPTZ")
                | (Self::Json(_), "JSONB")
        )
    }
}

/// A row of a table: its full name, and its values by column name (the column id among them).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub table: String,
    pub values: BTreeMap<String, Value>,
}

impl Row {
    /// The row's id, as text; empty when it has none.
    #[must_use]
    pub fn id(&self) -> &str {
        match self.values.get("id") {
            Some(Value::Text(s) | Value::Uuid(s)) => s,
            _ => "",
        }
    }
}

/// Every row, by table name; each table's rows in the order written.
pub type Rows = BTreeMap<String, Vec<Row>>;

/// A file of an owner's folder, embedded: its name and its SQL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct File {
    pub name: &'static str,
    pub sql: &'static str,
}

/// A version of an owner after its first, embedded: its number, its name and its SQL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Migration {
    pub version: u32,
    pub name: &'static str,
    pub sql: &'static str,
}

/// The columns of cortex.schema_identity the model does not hold.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    /// A UUIDv7.
    pub id: String,
    pub name: String,
    pub comment: Option<String>,
    /// RFC 3339, in UTC.
    pub created_at: String,
}

// --- step 5: an engine's tables ------------------------------------------------------------------------------------

/// An engine's own folder, declared as data, and its options as the rows of its tables.
pub trait Tables: Send + Sync {
    /// Its owner.toml.
    fn card(&self) -> &'static str;

    /// Its table files, each named by its table's full name (engine_example.table_options), in name order.
    fn files(&self) -> &[File];

    /// Its rules/ files, each named by its rule.
    fn rules(&self) -> &[File];

    /// Its seeds/ files.
    fn seeds(&self) -> &[File] {
        &[]
    }

    /// Its versions from 2 up and, when there are, 1 its migrations/1_tables.sql.
    fn migrations(&self) -> &[Migration] {
        &[]
    }

    /// Every option of every section of `schema` as rows of its own tables, with the ids of the parts they refer to
    /// and the cortex.id_counters rows of its own numbered ids.
    ///
    /// # Errors
    /// `<part id>: option <key> has no column in <engine>'s tables` for an option it cannot place.
    fn rows(&self, schema: &Schema) -> Result<Rows, String>;

    /// Puts every option back into the sections of a schema that [`cortex_schema`] made from the same rows.
    ///
    /// # Errors
    /// When a row cannot be read back as an option.
    fn read(&self, rows: &Rows, schema: &mut Schema) -> Result<(), String>;
}

// --- step 2: ids and counters --------------------------------------------------------------------------------------

macro_rules! numbered {
    ($($(#[$doc:meta])* $name:ident => $word:literal;)*) => {
        $($(#[$doc])* #[must_use] pub fn $name(parent: &str, n: usize) -> String { format!(concat!("{}", $word, "{}"), parent, n) })*
    };
}

numbered! {
    /// `<object>.key<n>`: the primary key, when there is one, first, then the unique keys, then the identifier key.
    table_key_id => ".key";
    /// `<key>.<n>`.
    table_key_column_id => ".";
    /// `<object>.check<n>`.
    check_constraint_id => ".check";
    /// `<object>.index<n>`.
    index_id => ".index";
    /// `<index>.<n>`.
    index_part_id => ".";
    /// `<index>.include<n>`.
    index_include_id => ".include";
    /// `<object>.by<n>`.
    partition_field_id => ".by";
    /// `<object>.partition<n>`.
    partition_id => ".partition";
    /// `<object>.order<n>`.
    sort_field_id => ".order";
    /// `<object>.value<n>`.
    enum_value_id => ".value";
    /// `<object>.field<n>`.
    composite_type_field_id => ".field";
    /// `<routine>.param<n>`.
    routine_parameter_id => ".param";
    /// `<trigger>.on<n>`.
    trigger_event_id => ".on";
    /// `<object>.tag<n>`.
    object_tag_id => ".tag";
    /// `<object>.read<n>`.
    object_read_id => ".read";
    /// `<relationship>.<n>`.
    relationship_column_id => ".";
}

/// `statement<n>`.
#[must_use]
pub fn verbatim_statement_id(n: usize) -> String {
    format!("statement{n}")
}

/// An id without its trailing digits: the counter it was numbered under (`o_orders.key1` is `o_orders.key`).
#[must_use]
pub fn counter_id(id: &str) -> String {
    id.trim_end_matches(|c: char| c.is_ascii_digit()).to_string()
}

// --- the cortex's columns ------------------------------------------------------------------------------------------

/// Every cortex table cortex_rows writes, with its columns as its table file names them.
const CORTEX: &[(&str, &[&str])] = &[
    ("schema_identity", &["id", "name", "engine", "engine_version", "comment", "section_format", "created_at", "one"]),
    ("object_kinds", &["id", "name", "position"]),
    ("object_kind_parts", &["id", "kind", "slot"]),
    ("namespaces", &["id", "name", "parent", "position", "comment"]),
    ("subject_areas", &["id", "name", "colour", "position"]),
    ("objects", &["id", "kind", "namespace", "name", "position", "comment", "notes", "area"]),
    ("object_tags", &["id", "object", "position", "tag"]),
    ("object_reads", &["id", "object", "position", "reads"]),
    (
        "columns",
        &[
            "id",
            "object",
            "position",
            "name",
            "type",
            "nullable",
            "comment",
            "default_value",
            "generated_expression",
            "generated_stored",
        ],
    ),
    ("column_identities", &["id", "always", "start", "increment", "min_value", "max_value", "cache", "cycle"]),
    (
        "relationships",
        &[
            "id",
            "name",
            "from_object",
            "to_object",
            "position",
            "enforced",
            "on_delete",
            "on_update",
            "match_kind",
            "deferrable",
            "initially_deferred",
        ],
    ),
    ("relationship_columns", &["id", "relationship", "position", "from_column", "to_column"]),
    ("table_keys", &["id", "object", "position", "what", "name"]),
    ("table_key_columns", &["id", "key", "position", "column"]),
    ("check_constraints", &["id", "object", "position", "name", "expression"]),
    ("indexes", &["id", "object", "position", "name", "unique", "method", "condition"]),
    ("index_parts", &["id", "index", "position", "column", "expression", "direction", "nulls"]),
    ("index_includes", &["id", "index", "position", "column"]),
    ("table_partitionings", &["id", "strategy"]),
    ("partition_fields", &["id", "partitioning", "position", "column", "expression", "transform"]),
    ("partitions", &["id", "partitioning", "position", "name", "bounds"]),
    ("partition_parents", &["id", "parent", "bounds"]),
    ("sort_fields", &["id", "object", "position", "column", "transform", "direction", "nulls"]),
    ("view_queries", &["id", "text"]),
    ("sequences", &["id", "type", "start", "increment", "min_value", "max_value", "cache", "cycle", "owned_by"]),
    ("enum_values", &["id", "object", "position", "value"]),
    ("domains", &["id", "base", "default_value", "nullable"]),
    ("composite_type_fields", &["id", "object", "position", "name", "type", "comment"]),
    ("routines", &["id", "returns", "language", "deterministic", "security", "body"]),
    ("routine_parameters", &["id", "routine", "position", "name", "type", "mode", "default_value"]),
    ("triggers", &["id", "timing", "on", "condition", "body"]),
    ("trigger_events", &["id", "trigger", "position", "change"]),
    ("scheduled_events", &["id", "schedule", "preserve", "enabled", "body"]),
    ("verbatim_statements", &["id", "position", "kind", "text", "after_namespace", "after_object"]),
    ("required_extensions", &["id", "position"]),
    ("id_counters", &["id", "last"]),
];

/// Every reference between the cortex's rows: (table, column, the table its value is the id of).
const REFERS: &[(&str, &str, &str)] = &[
    ("object_kind_parts", "kind", "object_kinds"),
    ("namespaces", "parent", "namespaces"),
    ("objects", "kind", "object_kinds"),
    ("objects", "namespace", "namespaces"),
    ("objects", "area", "subject_areas"),
    ("object_tags", "object", "objects"),
    ("object_reads", "object", "objects"),
    ("object_reads", "reads", "objects"),
    ("columns", "object", "objects"),
    ("column_identities", "id", "columns"),
    ("relationships", "from_object", "objects"),
    ("relationships", "to_object", "objects"),
    ("relationship_columns", "relationship", "relationships"),
    ("relationship_columns", "from_column", "columns"),
    ("relationship_columns", "to_column", "columns"),
    ("table_keys", "object", "objects"),
    ("table_key_columns", "key", "table_keys"),
    ("table_key_columns", "column", "columns"),
    ("check_constraints", "object", "objects"),
    ("indexes", "object", "objects"),
    ("index_parts", "index", "indexes"),
    ("index_parts", "column", "columns"),
    ("index_includes", "index", "indexes"),
    ("index_includes", "column", "columns"),
    ("table_partitionings", "id", "objects"),
    ("partition_fields", "partitioning", "table_partitionings"),
    ("partition_fields", "column", "columns"),
    ("partitions", "partitioning", "table_partitionings"),
    ("partition_parents", "id", "objects"),
    ("partition_parents", "parent", "objects"),
    ("sort_fields", "object", "objects"),
    ("sort_fields", "column", "columns"),
    ("view_queries", "id", "objects"),
    ("sequences", "id", "objects"),
    ("sequences", "owned_by", "columns"),
    ("enum_values", "object", "objects"),
    ("domains", "id", "objects"),
    ("composite_type_fields", "object", "objects"),
    ("routines", "id", "objects"),
    ("routine_parameters", "routine", "routines"),
    ("triggers", "id", "objects"),
    ("triggers", "on", "objects"),
    ("trigger_events", "trigger", "triggers"),
    ("scheduled_events", "id", "objects"),
    ("verbatim_statements", "after_namespace", "namespaces"),
    ("verbatim_statements", "after_object", "objects"),
];

fn text(s: impl Into<String>) -> Value {
    Value::Text(s.into())
}

fn opt_text(s: Option<&str>) -> Value {
    s.map_or(Value::Null, |s| Value::Text(s.to_string()))
}

fn position(n: usize) -> Value {
    Value::Numeric(n.to_string())
}

fn opt_int(n: Option<i64>) -> Value {
    n.map_or(Value::Null, Value::Integer)
}

fn word<T: serde::Serialize>(v: &T) -> Value {
    match serde_json::to_value(v) {
        Ok(serde_json::Value::String(s)) => Value::Text(s),
        _ => Value::Null,
    }
}

fn opt_word<T: serde::Serialize>(v: Option<&T>) -> Value {
    v.map_or(Value::Null, word)
}

/// The snake-case name of a slot, as object_kind_parts writes it.
fn slot_name(slot: Slot) -> &'static str {
    match slot {
        Slot::Keys => "keys",
        Slot::Checks => "checks",
        Slot::Indexes => "indexes",
        Slot::Partitioning => "partitioning",
        Slot::PartitionOf => "partition_of",
        Slot::Order => "order",
        Slot::Query => "query",
        Slot::Sequence => "sequence",
        Slot::Values => "values",
        Slot::Domain => "domain",
        Slot::Fields => "fields",
        Slot::Routine => "routine",
        Slot::Trigger => "trigger",
        Slot::Event => "event",
    }
}

/// Rows being written: each with every column of its table, and the counters of the numbered ids given.
#[derive(Default)]
struct Writer {
    rows: Rows,
    counters: BTreeMap<String, usize>,
    /// The first value given for a column its table does not have: an error in every build.
    error: Option<String>,
}

impl Writer {
    fn put(&mut self, table: &str, values: &[(&str, Value)]) {
        let columns = CORTEX.iter().find(|(t, _)| *t == table).map_or(&[][..], |(_, c)| *c);
        let mut row = BTreeMap::new();
        for c in columns {
            row.insert((*c).to_string(), Value::Null);
        }
        for (c, v) in values {
            if !columns.contains(c) {
                self.error.get_or_insert_with(|| format!("cortex.{table}: no column {c}"));
                continue;
            }
            row.insert((*c).to_string(), v.clone());
        }
        let name = format!("cortex.{table}");
        self.rows.entry(name.clone()).or_default().push(Row { table: name, values: row });
    }

    /// A numbered id, its counter raised to `n` when it was lower.
    fn numbered(&mut self, id: String, n: usize) -> String {
        let c = self.counters.entry(counter_id(&id)).or_insert(0);
        *c = (*c).max(n);
        id
    }
}

// --- step 3: the cortex rows ---------------------------------------------------------------------------------------

/// The model and every slot of its sections as the rows of the cortex's model tables. Options are left to the
/// engine's [`Tables::rows`].
///
/// # Errors
/// `<part id>: <the layout's message>` for a section off the layout; `statement <n>: it follows <id>, which is neither
/// a namespace nor an object` for a kept statement after something else.
pub fn cortex_rows(schema: &Schema, engine: &dyn Engine, identity: &Identity) -> Result<Rows, String> {
    let mut w = Writer::default();
    let ss: SchemaSection = sections::read(&schema.engine_section).map_err(|e| format!("schema: {e}"))?;
    w.put(
        "schema_identity",
        &[
            ("id", Value::Uuid(identity.id.clone())),
            ("name", text(&identity.name)),
            ("engine", text(&schema.engine.id)),
            ("engine_version", text(&schema.engine.version)),
            ("comment", opt_text(identity.comment.as_deref())),
            ("section_format", Value::Integer(i64::from(ss.format))),
            ("created_at", Value::Timestamp(identity.created_at.clone())),
            ("one", Value::Bool(true)),
        ],
    );
    for (i, kind) in engine.kinds().iter().enumerate() {
        w.put("object_kinds", &[("id", text(kind.id)), ("name", text(kind.name)), ("position", position(i + 1))]);
        for slot in kind.slots {
            let name = slot_name(*slot);
            w.put(
                "object_kind_parts",
                &[("id", text(format!("{}.{name}", kind.id))), ("kind", text(kind.id)), ("slot", text(name))],
            );
        }
    }
    for (i, n) in schema.namespaces.iter().enumerate() {
        let _: crate::sections::NamespaceSection = sections::read(&n.engine).map_err(|e| format!("{}: {e}", n.id))?;
        w.put(
            "namespaces",
            &[
                ("id", text(n.id.as_str())),
                ("name", text(&n.name)),
                ("parent", opt_text(n.parent.as_ref().map(Id::as_str))),
                ("position", position(i + 1)),
                ("comment", opt_text(n.comment.as_deref())),
            ],
        );
    }
    for (i, a) in schema.areas.iter().enumerate() {
        w.put(
            "subject_areas",
            &[
                ("id", text(a.id.as_str())),
                ("name", text(&a.name)),
                ("colour", opt_text(a.colour.as_deref())),
                ("position", position(i + 1)),
            ],
        );
    }
    for (i, o) in schema.objects.iter().enumerate() {
        object_rows(&mut w, o, i + 1)?;
    }
    for (i, l) in schema.links.iter().enumerate() {
        link_rows(&mut w, l, i + 1)?;
    }
    for (i, k) in ss.kept.iter().enumerate() {
        let n = i + 1;
        let id = w.numbered(verbatim_statement_id(n), n);
        let (mut after_namespace, mut after_object) = (Value::Null, Value::Null);
        if let Some(after) = &k.after {
            if schema.namespace(after).is_some() {
                after_namespace = text(after.as_str());
            } else if schema.object(after).is_some() {
                after_object = text(after.as_str());
            } else {
                return Err(format!("statement {n}: it follows {after}, which is neither a namespace nor an object"));
            }
        }
        w.put(
            "verbatim_statements",
            &[
                ("id", text(id)),
                ("position", position(n)),
                ("kind", text(&k.kind)),
                ("text", text(&k.text)),
                ("after_namespace", after_namespace),
                ("after_object", after_object),
            ],
        );
    }
    for (i, r) in ss.requires.iter().enumerate() {
        w.put("required_extensions", &[("id", text(r)), ("position", position(i + 1))]);
    }
    let counters = std::mem::take(&mut w.counters);
    for (id, last) in counters {
        w.put("id_counters", &[("id", text(id)), ("last", Value::Integer(i64::try_from(last).unwrap_or(i64::MAX)))]);
    }
    match w.error {
        Some(e) => Err(e),
        None => Ok(w.rows),
    }
}

fn object_rows(w: &mut Writer, o: &Object, at: usize) -> Result<(), String> {
    let id = o.id.as_str();
    w.put(
        "objects",
        &[
            ("id", text(id)),
            ("kind", text(&o.kind)),
            ("namespace", text(o.namespace.as_str())),
            ("name", text(&o.name)),
            ("position", position(at)),
            ("comment", opt_text(o.comment.as_deref())),
            ("notes", opt_text(o.notes.as_deref())),
            ("area", opt_text(o.area.as_ref().map(Id::as_str))),
        ],
    );
    for (i, tag) in o.tags.iter().enumerate() {
        let tid = w.numbered(object_tag_id(id, i + 1), i + 1);
        w.put(
            "object_tags",
            &[("id", text(tid)), ("object", text(id)), ("position", position(i + 1)), ("tag", text(tag))],
        );
    }
    for (i, r) in o.reads.iter().enumerate() {
        let rid = w.numbered(object_read_id(id, i + 1), i + 1);
        w.put(
            "object_reads",
            &[("id", text(rid)), ("object", text(id)), ("position", position(i + 1)), ("reads", text(r.as_str()))],
        );
    }
    for (i, c) in o.columns.iter().enumerate() {
        column_rows(w, id, c, i + 1)?;
    }
    let s: ObjectSection = sections::read(&o.engine).map_err(|e| format!("{id}: {e}"))?;
    let mut key = 0;
    let mut put_key = |w: &mut Writer, what: &str, name: Option<&str>, columns: &[Id]| {
        key += 1;
        let kid = w.numbered(table_key_id(id, key), key);
        w.put(
            "table_keys",
            &[
                ("id", text(&kid)),
                ("object", text(id)),
                ("position", position(key)),
                ("what", text(what)),
                ("name", opt_text(name)),
            ],
        );
        for (j, c) in columns.iter().enumerate() {
            let cid = w.numbered(table_key_column_id(&kid, j + 1), j + 1);
            w.put(
                "table_key_columns",
                &[("id", text(cid)), ("key", text(&kid)), ("position", position(j + 1)), ("column", text(c.as_str()))],
            );
        }
    };
    if let Some(pk) = &s.keys.primary {
        put_key(w, "primary", pk.name.as_deref(), &pk.columns);
    }
    for u in &s.keys.unique {
        put_key(w, "unique", u.name.as_deref(), &u.columns);
    }
    if !s.keys.identifier.is_empty() {
        put_key(w, "identifier", None, &s.keys.identifier);
    }
    for (i, c) in s.checks.iter().enumerate() {
        let cid = w.numbered(check_constraint_id(id, i + 1), i + 1);
        w.put(
            "check_constraints",
            &[
                ("id", text(cid)),
                ("object", text(id)),
                ("position", position(i + 1)),
                ("name", opt_text(c.name.as_deref())),
                ("expression", text(&c.expression)),
            ],
        );
    }
    for (i, x) in s.indexes.iter().enumerate() {
        let xid = w.numbered(index_id(id, i + 1), i + 1);
        w.put(
            "indexes",
            &[
                ("id", text(&xid)),
                ("object", text(id)),
                ("position", position(i + 1)),
                ("name", text(&x.name)),
                ("unique", Value::Bool(x.unique)),
                ("method", opt_text(x.method.as_deref())),
                ("condition", opt_text(x.condition.as_deref())),
            ],
        );
        for (j, p) in x.parts.iter().enumerate() {
            let pid = w.numbered(index_part_id(&xid, j + 1), j + 1);
            w.put(
                "index_parts",
                &[
                    ("id", text(pid)),
                    ("index", text(&xid)),
                    ("position", position(j + 1)),
                    ("column", opt_text(p.column.as_ref().map(Id::as_str))),
                    ("expression", opt_text(p.expression.as_deref())),
                    ("direction", opt_word(p.direction.as_ref())),
                    ("nulls", opt_word(p.nulls.as_ref())),
                ],
            );
        }
        for (j, c) in x.include.iter().enumerate() {
            let iid = w.numbered(index_include_id(&xid, j + 1), j + 1);
            w.put(
                "index_includes",
                &[
                    ("id", text(iid)),
                    ("index", text(&xid)),
                    ("position", position(j + 1)),
                    ("column", text(c.as_str())),
                ],
            );
        }
    }
    if let Some(p) = &s.partitioning {
        w.put("table_partitionings", &[("id", text(id)), ("strategy", opt_text(p.strategy.as_deref()))]);
        for (j, f) in p.by.iter().enumerate() {
            let fid = w.numbered(partition_field_id(id, j + 1), j + 1);
            w.put(
                "partition_fields",
                &[
                    ("id", text(fid)),
                    ("partitioning", text(id)),
                    ("position", position(j + 1)),
                    ("column", opt_text(f.column.as_ref().map(Id::as_str))),
                    ("expression", opt_text(f.expression.as_deref())),
                    ("transform", opt_text(f.transform.as_deref())),
                ],
            );
        }
        for (j, part) in p.partitions.iter().enumerate() {
            let pid = w.numbered(partition_id(id, j + 1), j + 1);
            w.put(
                "partitions",
                &[
                    ("id", text(pid)),
                    ("partitioning", text(id)),
                    ("position", position(j + 1)),
                    ("name", text(&part.name)),
                    ("bounds", text(&part.bounds)),
                ],
            );
        }
    }
    if let Some(p) = &s.partition_of {
        w.put(
            "partition_parents",
            &[("id", text(id)), ("parent", text(p.parent.as_str())), ("bounds", text(&p.bounds))],
        );
    }
    for (i, f) in s.order.iter().enumerate() {
        let fid = w.numbered(sort_field_id(id, i + 1), i + 1);
        w.put(
            "sort_fields",
            &[
                ("id", text(fid)),
                ("object", text(id)),
                ("position", position(i + 1)),
                ("column", text(f.column.as_str())),
                ("transform", opt_text(f.transform.as_deref())),
                ("direction", opt_word(f.direction.as_ref())),
                ("nulls", opt_word(f.nulls.as_ref())),
            ],
        );
    }
    if let Some(q) = &s.query {
        w.put("view_queries", &[("id", text(id)), ("text", text(q))]);
    }
    if let Some(q) = &s.sequence {
        w.put(
            "sequences",
            &[
                ("id", text(id)),
                ("type", opt_text(q.data_type.as_deref())),
                ("start", opt_int(q.start)),
                ("increment", opt_int(q.increment)),
                ("min_value", opt_int(q.min)),
                ("max_value", opt_int(q.max)),
                ("cache", opt_int(q.cache)),
                ("cycle", Value::Bool(q.cycle)),
                ("owned_by", opt_text(q.owned_by.as_ref().map(Id::as_str))),
            ],
        );
    }
    for (i, v) in s.values.iter().enumerate() {
        let vid = w.numbered(enum_value_id(id, i + 1), i + 1);
        w.put(
            "enum_values",
            &[("id", text(vid)), ("object", text(id)), ("position", position(i + 1)), ("value", text(v))],
        );
    }
    if let Some(d) = &s.domain {
        w.put(
            "domains",
            &[
                ("id", text(id)),
                ("base", text(&d.base)),
                ("default_value", opt_text(d.default.as_deref())),
                ("nullable", Value::Bool(d.null)),
            ],
        );
    }
    for (i, f) in s.fields.iter().enumerate() {
        let fid = w.numbered(composite_type_field_id(id, i + 1), i + 1);
        w.put(
            "composite_type_fields",
            &[
                ("id", text(fid)),
                ("object", text(id)),
                ("position", position(i + 1)),
                ("name", text(&f.name)),
                ("type", text(&f.data_type)),
                ("comment", opt_text(f.comment.as_deref())),
            ],
        );
    }
    if let Some(r) = &s.routine {
        w.put(
            "routines",
            &[
                ("id", text(id)),
                ("returns", opt_text(r.returns.as_deref())),
                ("language", opt_text(r.language.as_deref())),
                ("deterministic", r.deterministic.map_or(Value::Null, Value::Bool)),
                ("security", opt_text(r.security.as_deref())),
                ("body", text(&r.body)),
            ],
        );
        for (j, p) in r.parameters.iter().enumerate() {
            let pid = w.numbered(routine_parameter_id(id, j + 1), j + 1);
            w.put(
                "routine_parameters",
                &[
                    ("id", text(pid)),
                    ("routine", text(id)),
                    ("position", position(j + 1)),
                    ("name", text(&p.name)),
                    ("type", text(&p.data_type)),
                    ("mode", opt_word(p.mode.as_ref())),
                    ("default_value", opt_text(p.default.as_deref())),
                ],
            );
        }
    }
    if let Some(t) = &s.trigger {
        w.put(
            "triggers",
            &[
                ("id", text(id)),
                ("timing", word(&t.timing)),
                ("on", text(t.table.as_str())),
                ("condition", opt_text(t.condition.as_deref())),
                ("body", text(&t.body)),
            ],
        );
        for (j, c) in t.events.iter().enumerate() {
            let eid = w.numbered(trigger_event_id(id, j + 1), j + 1);
            w.put(
                "trigger_events",
                &[("id", text(eid)), ("trigger", text(id)), ("position", position(j + 1)), ("change", word(c))],
            );
        }
    }
    if let Some(e) = &s.event {
        w.put(
            "scheduled_events",
            &[
                ("id", text(id)),
                ("schedule", text(&e.schedule)),
                ("preserve", Value::Bool(e.preserve)),
                ("enabled", Value::Bool(e.enabled)),
                ("body", text(&e.body)),
            ],
        );
    }
    Ok(())
}

fn column_rows(w: &mut Writer, object: &str, c: &Column, at: usize) -> Result<(), String> {
    let s: ColumnSection = sections::read(&c.engine).map_err(|e| format!("{}: {e}", c.id))?;
    w.put(
        "columns",
        &[
            ("id", text(c.id.as_str())),
            ("object", text(object)),
            ("position", position(at)),
            ("name", text(&c.name)),
            ("type", text(&c.data_type)),
            ("nullable", Value::Bool(c.null)),
            ("comment", opt_text(c.comment.as_deref())),
            ("default_value", opt_text(s.default.as_deref())),
            ("generated_expression", opt_text(s.generated.as_ref().map(|g| g.expression.as_str()))),
            ("generated_stored", s.generated.as_ref().map_or(Value::Null, |g| Value::Bool(g.stored))),
        ],
    );
    if let Some(i) = &s.identity {
        w.put(
            "column_identities",
            &[
                ("id", text(c.id.as_str())),
                ("always", Value::Bool(i.always)),
                ("start", opt_int(i.start)),
                ("increment", opt_int(i.increment)),
                ("min_value", opt_int(i.min)),
                ("max_value", opt_int(i.max)),
                ("cache", opt_int(i.cache)),
                ("cycle", Value::Bool(i.cycle)),
            ],
        );
    }
    Ok(())
}

fn link_rows(w: &mut Writer, l: &Link, at: usize) -> Result<(), String> {
    let id = l.id.as_str();
    let s: LinkSection = sections::read(&l.engine).map_err(|e| format!("{id}: {e}"))?;
    if l.from.columns.len() != l.to.columns.len() {
        return Err(format!("{id}: its ends hold {} and {} columns", l.from.columns.len(), l.to.columns.len()));
    }
    w.put(
        "relationships",
        &[
            ("id", text(id)),
            ("name", opt_text(l.name.as_deref())),
            ("from_object", text(l.from.object.as_str())),
            ("to_object", text(l.to.object.as_str())),
            ("position", position(at)),
            ("enforced", Value::Bool(s.enforced)),
            ("on_delete", opt_word(s.on_delete.as_ref())),
            ("on_update", opt_word(s.on_update.as_ref())),
            ("match_kind", opt_text(s.match_kind.as_deref())),
            ("deferrable", Value::Bool(s.deferrable.is_some())),
            ("initially_deferred", s.deferrable.as_ref().map_or(Value::Null, |d| Value::Bool(d.initially_deferred))),
        ],
    );
    for (j, (f, t)) in l.from.columns.iter().zip(&l.to.columns).enumerate() {
        let cid = w.numbered(relationship_column_id(id, j + 1), j + 1);
        w.put(
            "relationship_columns",
            &[
                ("id", text(cid)),
                ("relationship", text(id)),
                ("position", position(j + 1)),
                ("from_column", text(f.as_str())),
                ("to_column", text(t.as_str())),
            ],
        );
    }
    Ok(())
}

// --- step 4: the schema back ---------------------------------------------------------------------------------------

/// Two decimals in text (`2`, `1.5`), compared by their values.
fn decimal_cmp(a: &str, b: &str) -> Ordering {
    let split = |s: &str| {
        let (neg, s) = s.strip_prefix('-').map_or((false, s), |r| (true, r));
        let (i, f) = s.split_once('.').unwrap_or((s, ""));
        (neg, i.trim_start_matches('0').to_string(), f.trim_end_matches('0').to_string())
    };
    let (na, ia, fa) = split(a);
    let (nb, ib, fb) = split(b);
    let zero = |i: &str, f: &str| i.is_empty() && f.is_empty();
    let (na, nb) = (na && !zero(&ia, &fa), nb && !zero(&ib, &fb));
    let magnitude = ia.len().cmp(&ib.len()).then_with(|| ia.cmp(&ib)).then_with(|| {
        let width = fa.len().max(fb.len());
        format!("{fa:0<width$}").cmp(&format!("{fb:0<width$}"))
    });
    match (na, nb) {
        (false, false) => magnitude,
        (true, true) => magnitude.reverse(),
        (true, false) => Ordering::Less,
        (false, true) => Ordering::Greater,
    }
}

/// Every child table, by the column that names its parent: grouped once, so a part's children are found at once.
const CHILDREN: &[(&str, &str)] = &[
    ("object_tags", "object"),
    ("object_reads", "object"),
    ("columns", "object"),
    ("table_keys", "object"),
    ("table_key_columns", "key"),
    ("check_constraints", "object"),
    ("indexes", "object"),
    ("index_parts", "index"),
    ("index_includes", "index"),
    ("partition_fields", "partitioning"),
    ("partitions", "partitioning"),
    ("sort_fields", "object"),
    ("enum_values", "object"),
    ("composite_type_fields", "object"),
    ("routine_parameters", "routine"),
    ("trigger_events", "trigger"),
    ("relationship_columns", "relationship"),
];

/// The rows, read once: each table sorted by position, each child table grouped by its parent, each table by id.
struct Back<'a> {
    sorted: BTreeMap<&'static str, Vec<&'a Row>>,
    children: BTreeMap<&'static str, BTreeMap<&'a str, Vec<&'a Row>>>,
    by_id: BTreeMap<&'static str, BTreeMap<&'a str, &'a Row>>,
}

impl<'a> Back<'a> {
    fn new(rows: &'a Rows) -> Self {
        let mut sorted = BTreeMap::new();
        let mut by_id = BTreeMap::new();
        for (name, _) in CORTEX {
            let mut list: Vec<&Row> =
                rows.get(&format!("cortex.{name}")).map(|r| r.iter().collect()).unwrap_or_default();
            list.sort_by(|a, b| match (a.values.get("position"), b.values.get("position")) {
                (Some(Value::Numeric(x)), Some(Value::Numeric(y))) => decimal_cmp(x, y),
                _ => Ordering::Equal,
            });
            by_id.insert(*name, list.iter().map(|r| (r.id(), *r)).collect());
            sorted.insert(*name, list);
        }
        let mut children = BTreeMap::new();
        for (name, column) in CHILDREN {
            let mut groups: BTreeMap<&str, Vec<&Row>> = BTreeMap::new();
            for r in sorted.get(name).into_iter().flatten() {
                if let Some(Value::Text(parent)) = r.values.get(*column) {
                    groups.entry(parent.as_str()).or_default().push(*r);
                }
            }
            children.insert(*name, groups);
        }
        Self { sorted, children, by_id }
    }

    fn table(&self, name: &str) -> &[&'a Row] {
        self.sorted.get(name).map_or(&[], Vec::as_slice)
    }

    fn children(&self, name: &str, parent: &str) -> &[&'a Row] {
        self.children.get(name).and_then(|g| g.get(parent)).map_or(&[], Vec::as_slice)
    }

    fn own(&self, name: &str, id: &str) -> Option<&'a Row> {
        self.by_id.get(name).and_then(|t| t.get(id)).copied()
    }
}

/// A value as an error says it.
fn shown(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => "nothing".to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(Value::Integer(n)) => n.to_string(),
        Some(Value::Numeric(s) | Value::Text(s) | Value::Uuid(s) | Value::Timestamp(s) | Value::Json(s)) => s.clone(),
    }
}

fn never(r: &Row, c: &str) -> String {
    format!("{} {}: {c} is {}, which cortex_rows never writes", r.table, r.id(), shown(r.values.get(c)))
}

/// An optional text column: text, or nothing.
fn opt_str(r: &Row, c: &str) -> Result<Option<String>, String> {
    match r.values.get(c) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Text(s)) => Ok(Some(s.clone())),
        Some(_) => Err(never(r, c)),
    }
}

/// A text column its table file declares NOT NULL.
fn req_str(r: &Row, c: &str) -> Result<String, String> {
    opt_str(r, c)?.ok_or_else(|| never(r, c))
}

fn opt_bool(r: &Row, c: &str) -> Result<Option<bool>, String> {
    match r.values.get(c) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        Some(_) => Err(never(r, c)),
    }
}

fn req_bool(r: &Row, c: &str) -> Result<bool, String> {
    opt_bool(r, c)?.ok_or_else(|| never(r, c))
}

fn opt_i64(r: &Row, c: &str) -> Result<Option<i64>, String> {
    match r.values.get(c) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Integer(n)) => Ok(Some(*n)),
        Some(_) => Err(never(r, c)),
    }
}

/// An optional word of its column's CHECK list (a direction, an action, a mode), as the layout spells it.
fn opt_word_of<T: serde::de::DeserializeOwned>(r: &Row, c: &str) -> Result<Option<T>, String> {
    opt_str(r, c)?.map(|s| serde_json::from_value(serde_json::Value::String(s)).map_err(|_| never(r, c))).transpose()
}

fn req_word<T: serde::de::DeserializeOwned>(r: &Row, c: &str) -> Result<T, String> {
    opt_word_of(r, c)?.ok_or_else(|| never(r, c))
}

fn opt_id(r: &Row, c: &str) -> Result<Option<Id>, String> {
    opt_str(r, c)?.map(|s| Id::try_from(s).map_err(|_| never(r, c))).transpose()
}

fn req_id(r: &Row, c: &str) -> Result<Id, String> {
    opt_id(r, c)?.ok_or_else(|| never(r, c))
}

/// The schema the rows hold: the inverse of [`cortex_rows`], every option empty (the engine fills them).
///
/// # Errors
/// `<table> <row id>: refers to <id>, which no row holds`; `<table> <row id>: <column> is <value>, which cortex_rows
/// never writes`.
pub fn cortex_schema(rows: &Rows, engine: &dyn Engine) -> Result<Schema, String> {
    let _ = engine;
    let b = Back::new(rows);
    for (t, c, target) in REFERS {
        for r in b.table(t) {
            if let Some(Value::Text(v)) = r.values.get(*c)
                && b.own(target, v).is_none()
            {
                return Err(format!("cortex.{t} {}: refers to {v}, which no row holds", r.id()));
            }
        }
    }
    let identity = *b.table("schema_identity").first().ok_or("cortex.schema_identity: no row")?;
    let mut schema = Schema::new(&req_str(identity, "engine")?, &req_str(identity, "engine_version")?);
    for r in b.table("namespaces") {
        let mut n = Namespace::new(req_id(r, "id")?, req_str(r, "name")?);
        n.parent = opt_id(r, "parent")?;
        n.comment = opt_str(r, "comment")?;
        schema.namespaces.push(n);
    }
    for r in b.table("subject_areas") {
        let mut a = Area::new(req_id(r, "id")?, req_str(r, "name")?);
        a.colour = opt_str(r, "colour")?;
        schema.areas.push(a);
    }
    for r in b.table("objects") {
        schema.objects.push(object_back(&b, r)?);
    }
    for r in b.table("relationships") {
        schema.links.push(link_back(&b, r)?);
    }
    let kept = b
        .table("verbatim_statements")
        .iter()
        .map(|r| {
            Ok(Kept {
                kind: req_str(r, "kind")?,
                text: req_str(r, "text")?,
                after: match opt_id(r, "after_namespace")? {
                    Some(n) => Some(n),
                    None => opt_id(r, "after_object")?,
                },
                ..Kept::default()
            })
        })
        .collect::<Result<_, String>>()?;
    let format = match opt_i64(identity, "section_format")? {
        Some(n) => u32::try_from(n).map_err(|_| never(identity, "section_format"))?,
        None => return Err(never(identity, "section_format")),
    };
    let ss = SchemaSection {
        format,
        kept,
        requires: b.table("required_extensions").iter().map(|r| r.id().to_string()).collect(),
        ..SchemaSection::default()
    };
    schema.engine_section = sections::write(&ss);
    Ok(schema)
}

fn column_back(b: &Back<'_>, c: &Row) -> Result<Column, String> {
    let cid = req_id(c, "id")?;
    let mut col = Column::new(cid.clone(), req_str(c, "name")?, req_str(c, "type")?, req_bool(c, "nullable")?);
    col.comment = opt_str(c, "comment")?;
    let generated = match opt_str(c, "generated_expression")? {
        Some(expression) => Some(Generated {
            expression,
            stored: opt_bool(c, "generated_stored")?.ok_or_else(|| never(c, "generated_stored"))?,
            ..Generated::default()
        }),
        None => None,
    };
    let identity = match b.own("column_identities", cid.as_str()) {
        Some(i) => Some(ColumnIdentity {
            always: req_bool(i, "always")?,
            start: opt_i64(i, "start")?,
            increment: opt_i64(i, "increment")?,
            min: opt_i64(i, "min_value")?,
            max: opt_i64(i, "max_value")?,
            cache: opt_i64(i, "cache")?,
            cycle: req_bool(i, "cycle")?,
            ..ColumnIdentity::default()
        }),
        None => None,
    };
    let s = ColumnSection { default: opt_str(c, "default_value")?, generated, identity, ..ColumnSection::default() };
    col.engine = sections::write(&s);
    Ok(col)
}

fn object_back(b: &Back<'_>, r: &Row) -> Result<Object, String> {
    let id = req_id(r, "id")?;
    let ids = id.as_str();
    let mut o = Object::new(id.clone(), req_str(r, "kind")?, req_id(r, "namespace")?, req_str(r, "name")?);
    o.comment = opt_str(r, "comment")?;
    o.notes = opt_str(r, "notes")?;
    o.area = opt_id(r, "area")?;
    o.tags = b.children("object_tags", ids).iter().map(|t| req_str(t, "tag")).collect::<Result<_, _>>()?;
    o.reads = b.children("object_reads", ids).iter().map(|t| req_id(t, "reads")).collect::<Result<_, _>>()?;
    o.columns = b.children("columns", ids).iter().map(|c| column_back(b, c)).collect::<Result<_, _>>()?;
    let mut s = ObjectSection::default();
    for k in b.children("table_keys", ids) {
        let columns: Vec<Id> =
            b.children("table_key_columns", k.id()).iter().map(|c| req_id(c, "column")).collect::<Result<_, _>>()?;
        let key = Key { name: opt_str(k, "name")?, columns: columns.clone(), ..Key::default() };
        match req_str(k, "what")?.as_str() {
            "primary" => s.keys.primary = Some(key),
            "unique" => s.keys.unique.push(key),
            "identifier" => s.keys.identifier = columns,
            _ => return Err(never(k, "what")),
        }
    }
    s.checks = b
        .children("check_constraints", ids)
        .iter()
        .map(|c| Ok(Check { name: opt_str(c, "name")?, expression: req_str(c, "expression")?, ..Check::default() }))
        .collect::<Result<_, String>>()?;
    for x in b.children("indexes", ids) {
        let parts = b
            .children("index_parts", x.id())
            .iter()
            .map(|p| {
                Ok(IndexPart {
                    column: opt_id(p, "column")?,
                    expression: opt_str(p, "expression")?,
                    direction: opt_word_of::<Direction>(p, "direction")?,
                    nulls: opt_word_of::<Nulls>(p, "nulls")?,
                    ..IndexPart::default()
                })
            })
            .collect::<Result<_, String>>()?;
        s.indexes.push(Index {
            name: req_str(x, "name")?,
            unique: req_bool(x, "unique")?,
            method: opt_str(x, "method")?,
            condition: opt_str(x, "condition")?,
            parts,
            include: b
                .children("index_includes", x.id())
                .iter()
                .map(|i| req_id(i, "column"))
                .collect::<Result<_, _>>()?,
            ..Index::default()
        });
    }
    if let Some(p) = b.own("table_partitionings", ids) {
        let by = b
            .children("partition_fields", ids)
            .iter()
            .map(|f| {
                Ok(PartField {
                    column: opt_id(f, "column")?,
                    expression: opt_str(f, "expression")?,
                    transform: opt_str(f, "transform")?,
                    ..PartField::default()
                })
            })
            .collect::<Result<_, String>>()?;
        let partitions = b
            .children("partitions", ids)
            .iter()
            .map(|part| {
                Ok(Partition { name: req_str(part, "name")?, bounds: req_str(part, "bounds")?, ..Partition::default() })
            })
            .collect::<Result<_, String>>()?;
        s.partitioning =
            Some(Partitioning { strategy: opt_str(p, "strategy")?, by, partitions, ..Partitioning::default() });
    }
    if let Some(p) = b.own("partition_parents", ids) {
        s.partition_of = Some(PartitionOf::new(req_id(p, "parent")?, req_str(p, "bounds")?));
    }
    for f in b.children("sort_fields", ids) {
        let mut field = OrderField::new(req_id(f, "column")?);
        field.transform = opt_str(f, "transform")?;
        field.direction = opt_word_of::<Direction>(f, "direction")?;
        field.nulls = opt_word_of::<Nulls>(f, "nulls")?;
        s.order.push(field);
    }
    s.query = match b.own("view_queries", ids) {
        Some(q) => Some(req_str(q, "text")?),
        None => None,
    };
    if let Some(q) = b.own("sequences", ids) {
        s.sequence = Some(Sequence {
            data_type: opt_str(q, "type")?,
            start: opt_i64(q, "start")?,
            increment: opt_i64(q, "increment")?,
            min: opt_i64(q, "min_value")?,
            max: opt_i64(q, "max_value")?,
            cache: opt_i64(q, "cache")?,
            cycle: req_bool(q, "cycle")?,
            owned_by: opt_id(q, "owned_by")?,
            ..Sequence::default()
        });
    }
    s.values = b.children("enum_values", ids).iter().map(|v| req_str(v, "value")).collect::<Result<_, _>>()?;
    if let Some(d) = b.own("domains", ids) {
        s.domain = Some(Domain {
            base: req_str(d, "base")?,
            default: opt_str(d, "default_value")?,
            null: req_bool(d, "nullable")?,
            ..Domain::default()
        });
    }
    s.fields = b
        .children("composite_type_fields", ids)
        .iter()
        .map(|f| {
            Ok(Field {
                name: req_str(f, "name")?,
                data_type: req_str(f, "type")?,
                comment: opt_str(f, "comment")?,
                ..Field::default()
            })
        })
        .collect::<Result<_, String>>()?;
    if let Some(r) = b.own("routines", ids) {
        let parameters = b
            .children("routine_parameters", ids)
            .iter()
            .map(|p| {
                Ok(sections::Parameter {
                    name: req_str(p, "name")?,
                    data_type: req_str(p, "type")?,
                    mode: opt_word_of::<Mode>(p, "mode")?,
                    default: opt_str(p, "default_value")?,
                    ..sections::Parameter::default()
                })
            })
            .collect::<Result<_, String>>()?;
        s.routine = Some(Routine {
            returns: opt_str(r, "returns")?,
            language: opt_str(r, "language")?,
            deterministic: opt_bool(r, "deterministic")?,
            security: opt_str(r, "security")?,
            body: req_str(r, "body")?,
            parameters,
            ..Routine::default()
        });
    }
    if let Some(t) = b.own("triggers", ids) {
        let events: Vec<Change> = b
            .children("trigger_events", ids)
            .iter()
            .map(|e| req_word::<Change>(e, "change"))
            .collect::<Result<_, _>>()?;
        let mut trigger = Trigger::new(req_word::<Timing>(t, "timing")?, events, req_id(t, "on")?, req_str(t, "body")?);
        trigger.condition = opt_str(t, "condition")?;
        s.trigger = Some(trigger);
    }
    if let Some(e) = b.own("scheduled_events", ids) {
        s.event = Some(Event {
            schedule: req_str(e, "schedule")?,
            preserve: req_bool(e, "preserve")?,
            enabled: req_bool(e, "enabled")?,
            body: req_str(e, "body")?,
            ..Event::default()
        });
    }
    o.engine = sections::write(&s);
    Ok(o)
}

fn link_back(b: &Back<'_>, r: &Row) -> Result<Link, String> {
    let id = req_id(r, "id")?;
    let pairs = b.children("relationship_columns", id.as_str());
    let from: Vec<Id> = pairs.iter().map(|p| req_id(p, "from_column")).collect::<Result<_, _>>()?;
    let to: Vec<Id> = pairs.iter().map(|p| req_id(p, "to_column")).collect::<Result<_, _>>()?;
    let mut link = Link::new(id, Ends::new(req_id(r, "from_object")?, from), Ends::new(req_id(r, "to_object")?, to));
    link.name = opt_str(r, "name")?;
    let deferrable = if req_bool(r, "deferrable")? {
        let initially = opt_bool(r, "initially_deferred")?.ok_or_else(|| never(r, "initially_deferred"))?;
        Some(Deferrable { initially_deferred: initially, ..Deferrable::default() })
    } else {
        None
    };
    let s = LinkSection {
        enforced: req_bool(r, "enforced")?,
        on_delete: opt_word_of::<Action>(r, "on_delete")?,
        on_update: opt_word_of::<Action>(r, "on_update")?,
        match_kind: opt_str(r, "match_kind")?,
        deferrable,
        ..LinkSection::default()
    };
    link.engine = sections::write(&s);
    Ok(link)
}

/// The columns of a table file and their types, as its CREATE TABLE writes them (`"collation"` unquoted).
#[must_use]
pub(crate) fn columns_of(sql: &str) -> Vec<(String, String)> {
    const TYPES: [&str; 8] = ["TEXT", "INTEGER", "BIGINT", "NUMERIC", "BOOLEAN", "UUID", "TIMESTAMPTZ", "JSONB"];
    let Some(start) = sql.find("CREATE TABLE ") else { return Vec::new() };
    let body = &sql[start..];
    let body = &body[..body.find("\n);").unwrap_or(body.len())];
    body.lines()
        .skip(1)
        .filter(|l| l.starts_with(' '))
        .filter_map(|l| {
            let mut words = l.split_whitespace();
            let name = words.next()?.trim_matches('"');
            let ty = words.next()?.trim_end_matches(',');
            let named = name.starts_with(|c: char| c.is_ascii_lowercase() || c == '_')
                && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
            (named && TYPES.contains(&ty)).then(|| (name.to_string(), ty.to_string()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decimals_compare_by_their_values() {
        assert_eq!(decimal_cmp("2", "10"), Ordering::Less);
        assert_eq!(decimal_cmp("1.5", "1.25"), Ordering::Greater);
        assert_eq!(decimal_cmp("1.50", "1.5"), Ordering::Equal);
        assert_eq!(decimal_cmp("0.5", "1"), Ordering::Less);
    }

    #[test]
    fn a_counter_is_the_id_without_its_number() {
        assert_eq!(counter_id("o_orders.key1"), "o_orders.key");
        assert_eq!(counter_id("o_orders.key1.2"), "o_orders.key1.");
        assert_eq!(counter_id("statement4"), "statement");
    }
}
