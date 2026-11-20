//! Writing the model as PostgreSQL DDL that PostgreSQL accepts, in dependency order:
//! schemas, types, sequences, tables (with their keys, checks, indexes and comments), partitions, sequence owners,
//! views, foreign keys. Kept statements go back right after the object they followed in the dump.

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;

use schema_forge_core::{Action, Direction, Id, Index, Nulls, Schema, Table, TypeKind, View};

use super::types::write as write_type;

/// The whole schema as PostgreSQL DDL.
#[must_use]
pub fn generate(schema: &Schema) -> String {
    let mut w = Writer { schema, out: String::new(), names: names(schema), type_names: type_names(schema) };
    w.kept_after(None);
    for n in &schema.namespaces {
        if n.name != "public" {
            let _ = writeln!(w.out, "CREATE SCHEMA IF NOT EXISTS {};", qi(&n.name));
            if let Some(c) = &n.comment {
                let _ = writeln!(w.out, "COMMENT ON SCHEMA {} IS {};", qi(&n.name), lit(c));
            }
            w.out.push('\n');
        }
        w.kept_after(Some(&n.id));
    }
    for t in &schema.types {
        w.type_def(t);
        w.kept_after(Some(&t.id));
    }
    for q in &schema.sequences {
        w.sequence(q);
        w.kept_after(Some(&q.id));
    }
    // In the model's order, a designed partition held back only until its parent is written.
    let mut written: HashSet<&Id> = HashSet::new();
    let mut waiting: Vec<&Table> = Vec::new();
    for t in &schema.tables {
        if t.partition_of.as_ref().is_some_and(|p| !written.contains(&p.parent)) {
            waiting.push(t);
            continue;
        }
        let mut ready = vec![t];
        while let Some(t) = ready.pop() {
            w.table(t);
            w.kept_after(Some(&t.id));
            written.insert(&t.id);
            let (now, still): (Vec<&Table>, Vec<&Table>) = waiting
                .into_iter()
                .partition(|p| p.partition_of.as_ref().is_some_and(|po| written.contains(&po.parent)));
            waiting = still;
            ready.extend(now.into_iter().rev());
        }
    }
    for t in waiting {
        w.table(t);
        w.kept_after(Some(&t.id));
    }
    for q in &schema.sequences {
        if let Some(owner) = &q.owned_by {
            let _ = writeln!(
                w.out,
                "ALTER SEQUENCE {} OWNED BY {};\n",
                w.qname(&q.namespace, &q.name),
                w.column_path(owner)
            );
        }
    }
    for v in crate::views_in_order(schema) {
        w.view(v);
        w.kept_after(Some(&v.id));
    }
    for r in &schema.relationships {
        w.foreign_key(r);
        w.kept_after(Some(&r.id));
    }
    w.out
}

/// One object's definition (a table with its indexes and comments, a view, a type or a sequence), as it is
/// written in the whole schema; `None` when no object has that id.
#[must_use]
pub fn definition(schema: &Schema, id: &Id) -> Option<String> {
    let mut w = Writer { schema, out: String::new(), names: names(schema), type_names: type_names(schema) };
    if let Some(t) = schema.tables.iter().find(|t| &t.id == id) {
        w.table(t);
        for r in schema.relationships.iter().filter(|r| &r.from.table == id) {
            w.foreign_key(r);
        }
    } else if let Some(v) = schema.views.iter().find(|v| &v.id == id) {
        w.view(v);
    } else if let Some(t) = schema.types.iter().find(|t| &t.id == id) {
        w.type_def(t);
    } else if let Some(q) = schema.sequences.iter().find(|q| &q.id == id) {
        w.sequence(q);
    } else {
        return None;
    }
    Some(w.out.trim_end().to_string() + "\n")
}

struct Writer<'s> {
    schema: &'s Schema,
    out: String,
    /// Every namespace's name, by id.
    names: HashMap<Id, String>,
    /// User-defined types as columns name them (`public.order_status`).
    type_names: HashMap<Id, String>,
}

fn names(schema: &Schema) -> HashMap<Id, String> {
    schema.namespaces.iter().map(|n| (n.id.clone(), n.name.clone())).collect()
}

fn type_names(schema: &Schema) -> HashMap<Id, String> {
    let ns = names(schema);
    schema
        .types
        .iter()
        .map(|t| {
            (t.id.clone(), format!("{}.{}", qi(ns.get(&t.namespace).map_or("public", String::as_str)), qi(&t.name)))
        })
        .collect()
}

impl Writer<'_> {
    fn kept_after(&mut self, id: Option<&Id>) {
        for k in self.schema.kept.iter().filter(|k| k.after.as_ref() == id) {
            if k.text.starts_with('\\') {
                let _ = writeln!(self.out, "{}\n", k.text);
            } else {
                let _ = writeln!(self.out, "{};\n", k.text);
            }
        }
    }

    fn qname(&self, namespace: &Id, name: &str) -> String {
        format!("{}.{}", qi(self.names.get(namespace).map_or("public", String::as_str)), qi(name))
    }

    fn table_name(&self, id: &Id) -> String {
        self.schema.tables.iter().find(|t| &t.id == id).map(|t| self.qname(&t.namespace, &t.name)).unwrap_or_default()
    }

    /// `ns.table.column` for a column id (for `OWNED BY`).
    fn column_path(&self, id: &Id) -> String {
        for t in &self.schema.tables {
            if let Some(c) = t.columns.iter().find(|c| &c.id == id) {
                return format!("{}.{}", self.qname(&t.namespace, &t.name), qi(&c.name));
            }
        }
        String::new()
    }

    fn type_def(&mut self, t: &schema_forge_core::TypeDef) {
        let name = self.qname(&t.namespace, &t.name);
        match &t.kind {
            TypeKind::Enum { values } => {
                let values: Vec<String> = values.iter().map(|v| format!("    {}", lit(v))).collect();
                let _ = writeln!(self.out, "CREATE TYPE {name} AS ENUM (\n{}\n);", values.join(",\n"));
            }
            TypeKind::Composite { fields } => {
                let fields: Vec<String> = fields
                    .iter()
                    .map(|f| format!("    {} {}", qi(&f.name), write_type(&f.data_type, &self.type_names)))
                    .collect();
                let _ = writeln!(self.out, "CREATE TYPE {name} AS (\n{}\n);", fields.join(",\n"));
            }
            TypeKind::Domain { base, default, not_null, checks } => {
                let _ = write!(self.out, "CREATE DOMAIN {name} AS {}", write_type(base, &self.type_names));
                if let Some(d) = default {
                    let _ = write!(self.out, " DEFAULT {d}");
                }
                if *not_null {
                    self.out.push_str(" NOT NULL");
                }
                for c in checks {
                    let _ = write!(self.out, "\n    {c}");
                }
                self.out.push_str(";\n");
            }
        }
        if let Some(c) = &t.comment {
            let what = if matches!(t.kind, TypeKind::Domain { .. }) { "DOMAIN" } else { "TYPE" };
            let _ = writeln!(self.out, "COMMENT ON {what} {name} IS {};", lit(c));
        }
        self.out.push('\n');
    }

    fn sequence(&mut self, q: &schema_forge_core::Sequence) {
        let _ = write!(self.out, "CREATE SEQUENCE {}", self.qname(&q.namespace, &q.name));
        if let Some(t) = &q.data_type {
            let _ = write!(self.out, "\n    AS {}", write_type(t, &self.type_names));
        }
        for (word, v) in [
            ("START WITH", q.start),
            ("INCREMENT BY", q.increment),
            ("MINVALUE", q.min),
            ("MAXVALUE", q.max),
            ("CACHE", q.cache),
        ] {
            if let Some(v) = v {
                let _ = write!(self.out, "\n    {word} {v}");
            }
        }
        if q.cycle {
            self.out.push_str("\n    CYCLE");
        }
        self.out.push_str(";\n\n");
    }

    fn table(&mut self, t: &Table) {
        let name = self.qname(&t.namespace, &t.name);
        if let Some(p) = &t.partition_of {
            let _ = writeln!(self.out, "CREATE TABLE {name} PARTITION OF {} {};", self.table_name(&p.parent), p.bounds);
        } else {
            let pg = t.options.postgres.clone().unwrap_or_default();
            let unlogged = if pg.unlogged { "UNLOGGED " } else { "" };
            let col = |id: &Id| t.columns.iter().find(|c| &c.id == id).map(|c| qi(&c.name)).unwrap_or_default();
            let mut lines: Vec<String> = t.columns.iter().map(|c| self.column(c)).collect();
            if let Some(pk) = &t.primary_key {
                let cols: Vec<String> = pk.columns.iter().map(&col).collect();
                lines.push(format!("    {}PRIMARY KEY ({})", named(pk.name.as_deref()), cols.join(", ")));
            }
            for u in &t.uniques {
                let cols: Vec<String> = u.columns.iter().map(&col).collect();
                let nulls = if u.nulls_distinct { "" } else { " NULLS NOT DISTINCT" };
                lines.push(format!("    {}UNIQUE{nulls} ({})", named(u.name.as_deref()), cols.join(", ")));
            }
            for c in &t.checks {
                lines.push(format!("    {}CHECK ({})", named(c.name.as_deref()), c.expression));
            }
            let _ = write!(self.out, "CREATE {unlogged}TABLE {name} (\n{}\n)", lines.join(",\n"));
            if !pg.inherits.is_empty() {
                let parents: Vec<String> = pg.inherits.iter().map(|p| self.table_name(p)).collect();
                let _ = write!(self.out, "\nINHERITS ({})", parents.join(", "));
            }
            if let Some(p) = &pg.partition_by {
                let _ = write!(self.out, "\nPARTITION BY {p}");
            }
            if let Some(s) = &pg.storage {
                let _ = write!(self.out, "\nWITH ({s})");
            }
            if let Some(ts) = &pg.tablespace {
                let _ = write!(self.out, "\nTABLESPACE {}", qi(ts));
            }
            self.out.push_str(";\n");
        }
        if let Some(c) = &t.comment {
            let _ = writeln!(self.out, "COMMENT ON TABLE {name} IS {};", lit(c));
        }
        for c in &t.columns {
            if let Some(comment) = &c.comment {
                let _ = writeln!(self.out, "COMMENT ON COLUMN {name}.{} IS {};", qi(&c.name), lit(comment));
            }
        }
        for i in &t.indexes {
            let cols: HashMap<&Id, &str> = t.columns.iter().map(|c| (&c.id, c.name.as_str())).collect();
            self.index(i, &name, &cols);
        }
        self.out.push('\n');
    }

    fn column(&self, c: &schema_forge_core::Column) -> String {
        let mut s = format!("    {} {}", qi(&c.name), write_type(&c.data_type, &self.type_names));
        if let Some(coll) = &c.collation {
            let _ = write!(s, " COLLATE {}", qi(coll));
        }
        if let Some(g) = &c.generated {
            let _ = write!(s, " GENERATED ALWAYS AS ({}) STORED", g.expression);
        }
        if let Some(d) = &c.default {
            let _ = write!(s, " DEFAULT {d}");
        }
        if !c.nullable {
            s.push_str(" NOT NULL");
        }
        if let Some(id) = &c.identity {
            let how = if id.always { "ALWAYS" } else { "BY DEFAULT" };
            let _ = write!(s, " GENERATED {how} AS IDENTITY");
            if let Some(opts) = &id.options {
                let _ = write!(s, " ({opts})");
            }
        }
        s
    }

    fn index(&mut self, i: &Index, on: &str, cols: &HashMap<&Id, &str>) {
        let unique = if i.unique { "UNIQUE " } else { "" };
        let method = i.method.as_ref().map(|m| format!(" USING {m}")).unwrap_or_default();
        let parts: Vec<String> = i
            .parts
            .iter()
            .map(|p| {
                let mut s = match (&p.column, &p.expression) {
                    (Some(id), _) => qi(cols.get(id).copied().unwrap_or_default()),
                    (None, Some(e)) => e.clone(),
                    (None, None) => String::new(),
                };
                match p.direction {
                    Some(Direction::Asc) => s.push_str(" ASC"),
                    Some(Direction::Desc) => s.push_str(" DESC"),
                    None => {}
                }
                match p.nulls {
                    Some(Nulls::First) => s.push_str(" NULLS FIRST"),
                    Some(Nulls::Last) => s.push_str(" NULLS LAST"),
                    None => {}
                }
                s
            })
            .collect();
        let _ = write!(self.out, "CREATE {unique}INDEX {} ON {on}{method} ({})", qi(&i.name), parts.join(", "));
        if !i.include.is_empty() {
            let inc: Vec<String> = i.include.iter().map(|id| qi(cols.get(id).copied().unwrap_or_default())).collect();
            let _ = write!(self.out, " INCLUDE ({})", inc.join(", "));
        }
        if let Some(w) = &i.predicate {
            let _ = write!(self.out, " WHERE {w}");
        }
        self.out.push_str(";\n");
    }

    fn view(&mut self, v: &View) {
        let name = self.qname(&v.namespace, &v.name);
        let pg = v.options.postgres.clone().unwrap_or_default();
        let kind = if pg.materialized { "MATERIALIZED VIEW" } else { "VIEW" };
        let _ = write!(self.out, "CREATE {kind} {name}");
        if let Some(with) = &pg.with {
            let _ = write!(self.out, " WITH ({with})");
        }
        let _ = write!(self.out, " AS\n {}", v.definition);
        if pg.materialized && !pg.with_data {
            self.out.push_str("\n  WITH NO DATA");
        }
        if let Some(opt) = &pg.check_option {
            let _ = write!(self.out, "\n  WITH {} CHECK OPTION", opt.to_uppercase());
        }
        self.out.push_str(";\n");
        if let Some(c) = &v.comment {
            let _ = writeln!(self.out, "COMMENT ON {kind} {name} IS {};", lit(c));
        }
        for i in &pg.indexes {
            self.index(i, &name, &HashMap::new());
        }
        self.out.push('\n');
    }

    fn foreign_key(&mut self, r: &schema_forge_core::Relationship) {
        let col_names = |table: &Id, ids: &[Id]| -> Vec<String> {
            let t = self.schema.tables.iter().find(|t| &t.id == table);
            ids.iter()
                .map(|id| {
                    t.and_then(|t| t.columns.iter().find(|c| &c.id == id)).map(|c| qi(&c.name)).unwrap_or_default()
                })
                .collect()
        };
        // A partitioned table takes its foreign key whole (PostgreSQL refuses ONLY there), as pg_dump writes it.
        let partitioned = self
            .schema
            .tables
            .iter()
            .find(|t| t.id == r.from.table)
            .is_some_and(|t| t.options.postgres.as_ref().is_some_and(|p| p.partition_by.is_some()));
        let _ = write!(
            self.out,
            "ALTER TABLE {}{}\n    ADD {}FOREIGN KEY ({}) REFERENCES {}({})",
            if partitioned { "" } else { "ONLY " },
            self.table_name(&r.from.table),
            named(r.name.as_deref()),
            col_names(&r.from.table, &r.from.columns).join(", "),
            self.table_name(&r.to.table),
            col_names(&r.to.table, &r.to.columns).join(", ")
        );
        if let Some(m) = &r.match_kind {
            let _ = write!(self.out, " MATCH {m}");
        }
        if let Some(a) = r.on_update {
            let _ = write!(self.out, " ON UPDATE {}", action(a));
        }
        if let Some(a) = r.on_delete {
            let _ = write!(self.out, " ON DELETE {}", action(a));
        }
        if let Some(d) = &r.deferrable {
            let _ = write!(self.out, " {d}");
        }
        self.out.push_str(";\n\n");
    }
}

/// Views after the views they read.
fn named(name: Option<&str>) -> String {
    name.map(|n| format!("CONSTRAINT {} ", qi(n))).unwrap_or_default()
}

fn action(a: Action) -> &'static str {
    match a {
        Action::NoAction => "NO ACTION",
        Action::Restrict => "RESTRICT",
        Action::Cascade => "CASCADE",
        Action::SetNull => "SET NULL",
        Action::SetDefault => "SET DEFAULT",
    }
}

/// A string literal: `'…'`, quotes doubled.
#[must_use]
pub fn lit(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// An identifier, quoted only when it must be: not plain lowercase, or a reserved word.
#[must_use]
pub fn qi(name: &str) -> String {
    let plain = name.chars().next().is_some_and(|c| c.is_ascii_lowercase() || c == '_')
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '$');
    if plain && !RESERVED.contains(&name) { name.to_string() } else { format!("\"{}\"", name.replace('"', "\"\"")) }
}

/// PostgreSQL's reserved key words (and those reserved as column names), which must be quoted as names.
const RESERVED: &[&str] = &[
    "all",
    "analyse",
    "analyze",
    "and",
    "any",
    "array",
    "as",
    "asc",
    "asymmetric",
    "authorization",
    "between",
    "bigint",
    "binary",
    "bit",
    "boolean",
    "both",
    "case",
    "cast",
    "char",
    "character",
    "check",
    "coalesce",
    "collate",
    "collation",
    "column",
    "concurrently",
    "constraint",
    "create",
    "cross",
    "current_catalog",
    "current_date",
    "current_role",
    "current_schema",
    "current_time",
    "current_timestamp",
    "current_user",
    "dec",
    "decimal",
    "default",
    "deferrable",
    "desc",
    "distinct",
    "do",
    "else",
    "end",
    "except",
    "exists",
    "extract",
    "false",
    "fetch",
    "float",
    "for",
    "foreign",
    "freeze",
    "from",
    "full",
    "grant",
    "greatest",
    "group",
    "grouping",
    "having",
    "ilike",
    "in",
    "initially",
    "inner",
    "inout",
    "int",
    "integer",
    "intersect",
    "interval",
    "into",
    "is",
    "isnull",
    "join",
    "lateral",
    "leading",
    "least",
    "left",
    "like",
    "limit",
    "localtime",
    "localtimestamp",
    "national",
    "natural",
    "nchar",
    "none",
    "normalize",
    "not",
    "notnull",
    "null",
    "nullif",
    "numeric",
    "offset",
    "on",
    "only",
    "or",
    "order",
    "out",
    "outer",
    "overlaps",
    "overlay",
    "placing",
    "position",
    "precision",
    "primary",
    "real",
    "references",
    "returning",
    "right",
    "row",
    "select",
    "session_user",
    "setof",
    "similar",
    "smallint",
    "some",
    "substring",
    "symmetric",
    "system_user",
    "table",
    "tablesample",
    "then",
    "time",
    "timestamp",
    "to",
    "trailing",
    "treat",
    "trim",
    "true",
    "union",
    "unique",
    "user",
    "using",
    "values",
    "varchar",
    "variadic",
    "verbose",
    "when",
    "where",
    "window",
    "with",
    "xmlattributes",
    "xmlconcat",
    "xmlelement",
    "xmlexists",
    "xmlforest",
    "xmlnamespaces",
    "xmlparse",
    "xmlpi",
    "xmlroot",
    "xmlserialize",
    "xmltable",
];
