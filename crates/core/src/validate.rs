//! The rules every schema keeps, whatever its project rules (docs/model.md, "Rules every schema keeps").

use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::{Id, Schema, Target};

/// One way a schema breaks the model's own rules.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    /// Where: the object's id, or the schema.
    pub at: String,
    pub message: String,
}

impl std::fmt::Display for Problem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.at, self.message)
    }
}

/// Every problem in `schema`, in a stable order; none when it keeps every rule.
#[must_use]
pub fn check(schema: &Schema) -> Vec<Problem> {
    let mut c = Checker { schema, problems: Vec::new() };
    c.run();
    c.problems
}

struct Checker<'a> {
    schema: &'a Schema,
    problems: Vec<Problem>,
}

impl Checker<'_> {
    fn problem(&mut self, at: &impl ToString, message: impl Into<String>) {
        self.problems.push(Problem { at: at.to_string(), message: message.into() });
    }

    fn run(&mut self) {
        let s = self.schema;
        if s.format != crate::FORMAT {
            self.problem(&"schema", format!("format {} is not {}", s.format, crate::FORMAT));
        }
        self.ids();
        let namespaces: BTreeSet<&Id> = s.namespaces.iter().map(|n| &n.id).collect();
        let areas: BTreeSet<&Id> = s.areas.iter().map(|a| &a.id).collect();
        for n in &s.namespaces {
            if let Some(p) = &n.parent {
                if !namespaces.contains(p) {
                    self.problem(&n.id, format!("its parent `{p}` is not a namespace"));
                }
                if s.target != Target::Iceberg {
                    self.problem(&n.id, "only Iceberg namespaces nest");
                }
            }
        }
        self.names();
        for t in &s.tables {
            if !namespaces.contains(&t.namespace) {
                self.problem(&t.id, format!("its namespace `{}` is not a namespace", t.namespace));
            }
            if let Some(a) = &t.area
                && !areas.contains(a)
            {
                self.problem(&t.id, format!("its area `{a}` is not an area"));
            }
            self.table(t);
        }
        for v in &s.views {
            if !namespaces.contains(&v.namespace) {
                self.problem(&v.id, format!("its namespace `{}` is not a namespace", v.namespace));
            }
            if let Some(a) = &v.area
                && !areas.contains(a)
            {
                self.problem(&v.id, format!("its area `{a}` is not an area"));
            }
            self.view_options(v);
        }
        self.relationships();
        self.view_reads();
        self.target_only();
    }

    /// Every id in the schema is used once.
    fn ids(&mut self) {
        let s = self.schema;
        let mut all: Vec<&Id> = Vec::new();
        all.extend(s.namespaces.iter().map(|o| &o.id));
        all.extend(s.areas.iter().map(|o| &o.id));
        for t in &s.tables {
            all.push(&t.id);
            all.extend(t.columns.iter().map(|o| &o.id));
            all.extend(t.uniques.iter().map(|o| &o.id));
            all.extend(t.checks.iter().map(|o| &o.id));
            all.extend(t.indexes.iter().map(|o| &o.id));
        }
        all.extend(s.relationships.iter().map(|o| &o.id));
        for v in &s.views {
            all.push(&v.id);
            if let Some(pg) = &v.options.postgres {
                all.extend(pg.indexes.iter().map(|o| &o.id));
            }
        }
        all.extend(s.sequences.iter().map(|o| &o.id));
        all.extend(s.types.iter().map(|o| &o.id));
        all.extend(s.kept.iter().map(|o| &o.id));
        let mut seen: BTreeMap<&Id, u32> = BTreeMap::new();
        for id in all {
            *seen.entry(id).or_default() += 1;
        }
        let twice: Vec<String> = seen.into_iter().filter(|(_, n)| *n > 1).map(|(id, _)| id.to_string()).collect();
        for id in twice {
            self.problem(&id, "this id is used more than once");
        }
    }

    /// Tables and views share one name space per namespace; columns are unique in their table.
    fn names(&mut self) {
        let s = self.schema;
        let mut taken: HashMap<(&Id, String), &Id> = HashMap::new();
        let relations = s
            .tables
            .iter()
            .map(|t| (&t.namespace, &t.name, &t.id))
            .chain(s.views.iter().map(|v| (&v.namespace, &v.name, &v.id)));
        let mut clashes = Vec::new();
        for (ns, name, id) in relations {
            if let Some(first) = taken.insert((ns, name.to_lowercase()), id) {
                clashes.push((id.clone(), format!("`{name}` is also the name of `{first}` in the same namespace")));
            }
        }
        for (id, m) in clashes {
            self.problem(&id, m);
        }
    }

    fn table(&mut self, t: &crate::Table) {
        let target = self.schema.target;
        let cols: HashMap<&Id, &crate::Column> = t.columns.iter().map(|c| (&c.id, c)).collect();
        let mut names = BTreeSet::new();
        let format_version = t.options.iceberg.as_ref().and_then(|i| i.format_version).unwrap_or(2);
        for c in &t.columns {
            let mut unknown = Vec::new();
            each_type(&c.data_type, &mut |dt| {
                if !crate::types::known(target, &dt.name) {
                    unknown.push(format!(
                        "`{}` is not a type of this target; keep it as `verbatim` or use one it has",
                        dt.name
                    ));
                }
                if dt.is_verbatim() && dt.text.is_none() {
                    unknown.push("a verbatim type needs its text".to_string());
                }
                if target == Target::Iceberg && format_version < 3 && crate::types::iceberg_v3_only(&dt.name) {
                    unknown.push(format!("`{}` needs Iceberg format version 3", dt.name));
                }
            });
            for m in unknown {
                self.problem(&c.id, m);
            }
            if !names.insert(c.name.to_lowercase()) {
                self.problem(&c.id, format!("`{}` is the name of another column of `{}`", c.name, t.name));
            }
            if c.field_id.is_some() && target != Target::Iceberg {
                self.problem(&c.id, "only Iceberg columns have field ids");
            }
            if target == Target::Iceberg && c.field_id.is_none() {
                self.problem(&c.id, "an Iceberg column needs a field id");
            }
        }
        if target == Target::Iceberg {
            let mut ids = Vec::new();
            for c in &t.columns {
                c.field_id.into_iter().for_each(|f| ids.push(f));
                nested_ids(&c.data_type, &mut ids);
            }
            let mut seen = BTreeSet::new();
            for f in ids {
                if !seen.insert(f) {
                    self.problem(&t.id, format!("field id {f} is used more than once"));
                }
            }
        }
        let owned = |what: &str, list: &[Id], this: &mut Self| {
            for id in list {
                if !cols.contains_key(id) {
                    this.problem(&t.id, format!("its {what} names `{id}`, which is not one of its columns"));
                }
            }
        };
        if let Some(pk) = &t.primary_key {
            owned("primary key", &pk.columns, self);
            for id in &pk.columns {
                if cols.get(id).is_some_and(|c| c.nullable) {
                    self.problem(id, "a primary key column cannot be nullable");
                }
            }
            if pk.columns.is_empty() {
                self.problem(&t.id, "its primary key has no columns");
            }
        }
        for u in &t.uniques {
            owned("unique key", &u.columns, self);
        }
        for i in &t.indexes {
            let parts: Vec<Id> = i.parts.iter().filter_map(|p| p.column.clone()).collect();
            owned("index", &parts, self);
            owned("index", &i.include, self);
            for p in &i.parts {
                if p.column.is_some() == p.expression.is_some() {
                    self.problem(&i.id, "each part is a column or an expression, not both or neither");
                }
            }
        }
        if let Some(p) = &t.partition_of {
            if target != Target::Postgres {
                self.problem(&t.id, "only PostgreSQL tables are partitions of another");
            } else if !self.schema.tables.iter().any(|o| o.id == p.parent) {
                self.problem(&t.id, format!("its parent `{}` is not a table", p.parent));
            }
        }
        if let Some(ice) = &t.options.iceberg {
            owned("identifier fields", &ice.identifier_fields, self);
            for id in &ice.identifier_fields {
                if let Some(c) = cols.get(id) {
                    if c.nullable {
                        self.problem(id, "an identifier field must be required (not nullable)");
                    }
                    if matches!(c.data_type.name.as_str(), "float" | "double") {
                        self.problem(id, "an identifier field cannot be float or double");
                    }
                    if matches!(c.data_type.name.as_str(), "list" | "map") {
                        self.problem(id, "an identifier field cannot be a list or a map");
                    }
                }
            }
            let sources: Vec<Id> = ice
                .partition_spec
                .iter()
                .map(|p| p.source.clone())
                .chain(ice.sort_order.iter().map(|s| s.source.clone()))
                .collect();
            owned("partition spec or sort order", &sources, self);
            if let Some(v) = ice.format_version
                && !(1..=3).contains(&v)
            {
                self.problem(&t.id, format!("format version {v} is not 1, 2 or 3"));
            }
        }
    }

    fn view_options(&mut self, v: &crate::View) {
        if let Some(pg) = &v.options.postgres
            && !pg.indexes.is_empty()
            && !pg.materialized
        {
            self.problem(&v.id, "only a materialized view has indexes");
        }
    }

    fn relationships(&mut self) {
        let s = self.schema;
        let tables: HashMap<&Id, &crate::Table> = s.tables.iter().map(|t| (&t.id, t)).collect();
        for r in &s.relationships {
            if r.enforced && s.target == Target::Iceberg {
                self.problem(&r.id, "Iceberg has no enforced relationships: this one must be logical");
            }
            let (Some(from), Some(to)) = (tables.get(&r.from.table), tables.get(&r.to.table)) else {
                self.problem(&r.id, "both ends must be tables of the schema");
                continue;
            };
            for (end, table) in [(&r.from, from), (&r.to, to)] {
                for c in &end.columns {
                    if !table.columns.iter().any(|col| &col.id == c) {
                        self.problem(&r.id, format!("`{c}` is not a column of `{}`", table.name));
                    }
                }
            }
            if r.from.columns.len() != r.to.columns.len() || r.from.columns.is_empty() {
                self.problem(&r.id, "both ends need the same number of columns, at least one");
            }
            let key_of_to = to.primary_key.as_ref().is_some_and(|pk| pk.columns == r.to.columns)
                || to.uniques.iter().any(|u| u.columns == r.to.columns)
                || to.options.iceberg.as_ref().is_some_and(|i| i.identifier_fields == r.to.columns);
            if !key_of_to {
                self.problem(&r.id, format!("it must point at a primary or unique key of `{}`", to.name));
            }
        }
    }

    fn view_reads(&mut self) {
        let s = self.schema;
        let relations: BTreeSet<&Id> = s.tables.iter().map(|t| &t.id).chain(s.views.iter().map(|v| &v.id)).collect();
        for v in &s.views {
            for r in &v.reads {
                if !relations.contains(r) {
                    self.problem(&v.id, format!("it reads `{r}`, which is not a table or view"));
                }
            }
        }
        // No view reads itself through other views.
        let reads: HashMap<&Id, &Vec<Id>> = s.views.iter().map(|v| (&v.id, &v.reads)).collect();
        for v in &s.views {
            let mut stack: Vec<&Id> = v.reads.iter().collect();
            let mut seen = BTreeSet::new();
            while let Some(next) = stack.pop() {
                if next == &v.id {
                    self.problem(&v.id, "it reads itself, through the views it reads");
                    break;
                }
                if seen.insert(next)
                    && let Some(more) = reads.get(next)
                {
                    stack.extend(more.iter());
                }
            }
        }
    }

    /// Options, objects and types that only one target has.
    fn target_only(&mut self) {
        let s = self.schema;
        let target = s.target;
        for t in &s.tables {
            let o = &t.options;
            let wrong = (o.mysql.is_some() && target != Target::Mysql)
                || (o.postgres.is_some() && target != Target::Postgres)
                || (o.iceberg.is_some() && target != Target::Iceberg);
            if wrong {
                self.problem(&t.id, "it carries options of another target");
            }
            if target == Target::Iceberg && (!t.indexes.is_empty() || !t.checks.is_empty() || !t.uniques.is_empty()) {
                self.problem(&t.id, "Iceberg has no indexes, checks or unique keys");
            }
        }
        for v in &s.views {
            let o = &v.options;
            let wrong = (o.mysql.is_some() && target != Target::Mysql)
                || (o.postgres.is_some() && target != Target::Postgres)
                || (o.iceberg.is_some() && target != Target::Iceberg);
            if wrong {
                self.problem(&v.id, "it carries options of another target");
            }
        }
        if target != Target::Postgres {
            for q in &s.sequences {
                self.problem(&q.id, "only PostgreSQL schemas have sequences");
            }
            for y in &s.types {
                self.problem(&y.id, "only PostgreSQL schemas have user-defined types");
            }
        }
    }
}

/// Calls `f` on `t` and every type inside it.
fn each_type(t: &crate::DataType, f: &mut impl FnMut(&crate::DataType)) {
    f(t);
    for field in &t.fields {
        each_type(&field.data_type, f);
    }
    if let Some(of) = &t.of {
        each_type(of, f);
    }
    if let Some(k) = &t.key {
        each_type(k, f);
    }
}

fn nested_ids(t: &crate::DataType, out: &mut Vec<i32>) {
    out.extend(t.element_id);
    out.extend(t.key_id);
    for f in &t.fields {
        out.push(f.field_id);
        nested_ids(&f.data_type, out);
    }
    if let Some(of) = &t.of {
        nested_ids(of, out);
    }
    if let Some(k) = &t.key {
        nested_ids(k, out);
    }
}
