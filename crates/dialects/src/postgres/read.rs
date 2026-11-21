//! Reading PostgreSQL DDL into the model.

use std::collections::{HashMap, HashSet};

use schema_forge_core::{
    Action, Check, Column, CompositeField, Direction, Ends, Generated, Id, Identity, Index, IndexPart, Kept, KeptKind,
    Kind, Namespace, Nulls, PartitionOf, PartitionPolicy, PartitionSeries, PostgresTable, PostgresView, PrimaryKey,
    Relationship, Schema, Sequence, Table, TableOptions, Target, TypeDef, TypeKind, Unique, View, ViewOptions,
};
use sqlparser::dialect::PostgreSqlDialect;
use sqlparser::tokenizer::Token;

use crate::cursor::{Case, Cur, ident_of, is_kw, string_of};
use crate::report::{Imported, Report};
use crate::split::{Statement, split};

use super::types;

/// What stops a dump from being read at all (a statement the model cannot describe is kept, not an error).
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Split(#[from] crate::split::SplitError),
}

/// How a statement was accounted for.
#[derive(Debug, Clone, PartialEq)]
enum Class {
    Modelled,
    Kept(KeptKind),
    Data,
}

/// A statement the model cannot fully describe: kept whole.
struct Fallback;

type Step<T> = Result<T, Fallback>;

/// Runs of at least this many consecutive daily or monthly partitions are held as one series.
const SERIES_MIN: usize = 4;

/// Reads a PostgreSQL dump (or any PostgreSQL DDL) into the model.
///
/// # Errors
/// When the text cannot be cut into statements (an unterminated string or comment).
pub fn import(text: &str) -> Result<Imported, Error> {
    let split = split(&PostgreSqlDialect {}, text)?;
    let mut r = Reader::new(&split.statements);
    for (k, st) in split.statements.iter().enumerate() {
        r.statement(k, st);
    }
    r.finish();
    let mut report = Report {
        statements: split.statements.len() + split.copy_blocks,
        copy_rows: split.copy_rows,
        partition_series: r.series,
        not_understood: r.not_understood,
        ..Report::default()
    };
    report.data += split.copy_blocks;
    for class in &r.classes {
        match class {
            Class::Modelled => report.modelled += 1,
            Class::Data => report.data += 1,
            Class::Kept(kind) => *report.kept.entry(kept_name(*kind).to_string()).or_default() += 1,
        }
    }
    Ok(Imported { schema: r.schema, report })
}

fn kept_name(kind: KeptKind) -> &'static str {
    match kind {
        KeptKind::Function => "function",
        KeptKind::Trigger => "trigger",
        KeptKind::Grant => "grant",
        KeptKind::Extension => "extension",
        KeptKind::Setting => "setting",
        KeptKind::Partitions => "partitions",
        KeptKind::Other => "other",
    }
}

/// A relation by name: a table or a view, by its index in the schema.
#[derive(Debug, Clone, Copy)]
enum Rel {
    Table(usize),
    View(usize),
}

struct Attach {
    parent: Id,
    child: Id,
    bounds: String,
    statement: usize,
}

struct PendingFk {
    table: Id,
    name: Option<String>,
    columns: Vec<String>,
    to: Vec<String>,
    to_columns: Vec<String>,
    rest: FkRest,
    statement: usize,
}

#[derive(Default, Clone)]
struct FkRest {
    on_delete: Option<Action>,
    on_update: Option<Action>,
    match_kind: Option<String>,
    deferrable: Option<String>,
}

struct Reader<'s> {
    statements: &'s [Statement],
    schema: Schema,
    classes: Vec<Class>,
    ids: HashSet<Id>,
    namespaces: HashMap<String, Id>,
    relations: HashMap<(String, String), Rel>,
    type_ids: HashMap<(String, String), Id>,
    sequences: HashMap<(String, String), usize>,
    /// The model object the dump last created or changed: where a kept statement goes back.
    last: Option<Id>,
    /// Statements that built or changed each table, for collapsing partition series.
    touched: HashMap<Id, Vec<usize>>,
    /// The statement each kept item came from.
    kept_from: HashMap<Id, usize>,
    attaches: Vec<Attach>,
    pending_fks: Vec<PendingFk>,
    series: usize,
    not_understood: Vec<(usize, String)>,
}

impl<'s> Reader<'s> {
    fn new(statements: &'s [Statement]) -> Self {
        Self {
            statements,
            schema: Schema::new(Target::Postgres),
            classes: vec![Class::Data; statements.len()],
            ids: HashSet::new(),
            namespaces: HashMap::new(),
            relations: HashMap::new(),
            type_ids: HashMap::new(),
            sequences: HashMap::new(),
            last: None,
            touched: HashMap::new(),
            kept_from: HashMap::new(),
            attaches: Vec::new(),
            pending_fks: Vec::new(),
            series: 0,
            not_understood: Vec::new(),
        }
    }

    fn new_id(&mut self, kind: Kind, parts: &[&str]) -> Id {
        let base = Id::from_name(kind, parts);
        let mut id = base.clone();
        let mut n = 2;
        while self.ids.contains(&id) {
            id = base.numbered(n);
            n += 1;
        }
        self.ids.insert(id.clone());
        id
    }

    fn keep(&mut self, k: usize, kind: KeptKind) {
        let id = self.new_id(Kind::Kept, &[&(self.schema.kept.len() + 1).to_string()]);
        self.kept_from.insert(id.clone(), k);
        self.schema.kept.push(Kept {
            id,
            kind,
            text: self.statements[k].text.clone(),
            after: self.last.clone(),
            refers_to: Vec::new(),
        });
        self.classes[k] = Class::Kept(kind);
    }

    fn not_understood(&mut self, k: usize) {
        let st = &self.statements[k];
        let first: String = st.text.split_whitespace().take(6).collect::<Vec<_>>().join(" ");
        self.not_understood.push((st.line, first));
        self.keep(k, KeptKind::Other);
    }

    fn modelled(&mut self, k: usize, id: &Id) {
        self.classes[k] = Class::Modelled;
        self.touched.entry(id.clone()).or_default().push(k);
        self.last = Some(id.clone());
    }

    fn statement(&mut self, k: usize, st: &Statement) {
        if st.meta {
            return self.keep(k, KeptKind::Setting);
        }
        let mut c = Cur::new(st, Case::FoldLower);
        let outcome: Option<KeptKind> = if c.is_kw("SET") || c.is_kw("RESET") {
            Some(KeptKind::Setting)
        } else if c.kws(&["SELECT", "pg_catalog"]) {
            if c.eat(&Token::Period) && c.is_kw("setval") {
                self.classes[k] = Class::Data;
                return;
            }
            Some(KeptKind::Setting)
        } else if c.is_kw("INSERT") || c.kws(&["REFRESH", "MATERIALIZED", "VIEW"]) {
            self.classes[k] = Class::Data;
            return;
        } else if c.is_kw("GRANT") || c.is_kw("REVOKE") || owner_to(st) {
            Some(KeptKind::Grant)
        } else if c.is_kw("CREATE") {
            c.bump();
            let replace = c.kws(&["OR", "REPLACE"]);
            if c.kw("SCHEMA") {
                return self.run(k, |r| r.create_schema(&mut c, k));
            } else if !replace && (c.is_kw("TABLE") || c.is_kw("UNLOGGED")) {
                return self.run(k, |r| r.create_table(&mut c, k));
            } else if c.is_kw("VIEW") || c.is_kw("MATERIALIZED") {
                return self.run(k, |r| r.create_view(&mut c, k));
            } else if !replace && (c.is_kw("INDEX") || c.is_kw("UNIQUE")) {
                return self.run(k, |r| r.create_index(&mut c, k));
            } else if !replace && c.is_kw("SEQUENCE") {
                return self.run(k, |r| r.create_sequence(&mut c, k));
            } else if !replace && c.is_kw("TYPE") {
                return self.run(k, |r| r.create_type(&mut c, k));
            } else if !replace && c.is_kw("DOMAIN") {
                return self.run(k, |r| r.create_domain(&mut c, k));
            } else if c.is_kw("EXTENSION") {
                Some(KeptKind::Extension)
            } else if c.is_kw("FUNCTION") || c.is_kw("PROCEDURE") || c.is_kw("AGGREGATE") {
                Some(KeptKind::Function)
            } else if c.is_kw("TRIGGER") || c.kws(&["CONSTRAINT", "TRIGGER"]) || c.kws(&["EVENT", "TRIGGER"]) {
                Some(KeptKind::Trigger)
            } else {
                None
            }
        } else if c.kws(&["COMMENT", "ON", "EXTENSION"]) {
            Some(KeptKind::Extension)
        } else if c.kws(&["COMMENT", "ON"]) {
            return self.run(k, |r| r.comment(&mut c, k));
        } else if c.kws(&["ALTER", "TABLE"]) {
            return self.run(k, |r| r.alter_table(&mut c, k));
        } else if c.kws(&["ALTER", "SEQUENCE"]) {
            return self.run(k, |r| r.alter_sequence(&mut c, k));
        } else if c.is_kw("ALTER") && (c.is_kw_at(1, "FUNCTION") || c.is_kw_at(1, "PROCEDURE")) {
            Some(KeptKind::Function)
        } else {
            None
        };
        match outcome {
            Some(kind) => self.keep(k, kind),
            None => self.not_understood(k),
        }
    }

    /// Runs one reading step; a statement it cannot describe is kept whole.
    fn run(&mut self, k: usize, step: impl FnOnce(&mut Self) -> Step<()>) {
        if step(self).is_err() {
            self.not_understood(k);
        }
    }

    fn namespace(&mut self, name: &str) -> Id {
        if let Some(id) = self.namespaces.get(name) {
            return id.clone();
        }
        let id = self.new_id(Kind::Namespace, &[name]);
        self.schema.namespaces.push(Namespace { id: id.clone(), name: name.to_string(), parent: None, comment: None });
        self.namespaces.insert(name.to_string(), id.clone());
        id
    }

    fn create_schema(&mut self, c: &mut Cur<'_>, k: usize) -> Step<()> {
        c.kws(&["IF", "NOT", "EXISTS"]);
        let name = c.ident().ok_or(Fallback)?;
        if !c.at_end() {
            return Err(Fallback);
        }
        let id = self.namespace(&name);
        self.modelled(k, &id);
        Ok(())
    }

    /// `ns.name` (or `name`, in `public`) as `(namespace, name)`.
    fn split_name(parts: &[String]) -> Step<(String, String)> {
        match parts {
            [name] => Ok(("public".to_string(), name.clone())),
            [ns, name] => Ok((ns.clone(), name.clone())),
            _ => Err(Fallback),
        }
    }

    fn table_index(&self, key: &(String, String)) -> Step<usize> {
        match self.relations.get(key) {
            Some(Rel::Table(i)) => Ok(*i),
            _ => Err(Fallback),
        }
    }

    fn create_table(&mut self, c: &mut Cur<'_>, k: usize) -> Step<()> {
        let unlogged = c.kw("UNLOGGED");
        if !c.kw("TABLE") {
            return Err(Fallback);
        }
        if c.kws(&["IF", "NOT", "EXISTS"]) {
            return Err(Fallback);
        }
        let key = Self::split_name(&c.qualified().ok_or(Fallback)?)?;
        if self.relations.contains_key(&key) {
            return Err(Fallback);
        }
        if c.kws(&["PARTITION", "OF"]) {
            let parent_key = Self::split_name(&c.qualified().ok_or(Fallback)?)?;
            let parent = self.schema.tables[self.table_index(&parent_key)?].id.clone();
            if c.is(&Token::LParen) {
                return Err(Fallback);
            }
            let bounds = c.rest().to_string();
            if !(bounds.starts_with("FOR VALUES") || bounds == "DEFAULT") {
                return Err(Fallback);
            }
            let ns = self.namespace(&key.0);
            let id = self.new_id(Kind::Table, &[&key.1]);
            self.push_table(Table {
                id: id.clone(),
                namespace: ns,
                name: key.1.clone(),
                comment: None,
                notes: None,
                tags: Vec::new(),
                area: None,
                columns: Vec::new(),
                primary_key: None,
                uniques: Vec::new(),
                checks: Vec::new(),
                indexes: Vec::new(),
                patterns: std::collections::BTreeMap::new(),
                partition_of: Some(PartitionOf { parent, bounds }),
                options: TableOptions::default(),
            });
            self.relations.insert(key, Rel::Table(self.schema.tables.len() - 1));
            self.modelled(k, &id);
            return Ok(());
        }
        let (from, to) = c.group().ok_or(Fallback)?;
        let draft = self.table_elements(c, from, to)?;
        let mut pg = PostgresTable { unlogged, ..PostgresTable::default() };
        while !c.at_end() {
            if c.kw("INHERITS") {
                let (a, b) = c.group().ok_or(Fallback)?;
                for (x, y) in c.commas(a, b) {
                    let mut inner = Cur { i: x, ..Cur::new(c.st, Case::FoldLower) };
                    let parent = Self::split_name(&inner.qualified().ok_or(Fallback)?)?;
                    if inner.i != y {
                        return Err(Fallback);
                    }
                    pg.inherits.push(self.schema.tables[self.table_index(&parent)?].id.clone());
                }
            } else if c.kws(&["PARTITION", "BY"]) {
                let start = c.i;
                let end = c.find_top(start, c.toks().len(), |t| is_kw(t, "TABLESPACE") || is_kw(t, "WITH"));
                pg.partition_by = Some(c.text(start, end).to_string());
                c.i = end;
            } else if c.kw("WITH") {
                let (a, b) = c.group().ok_or(Fallback)?;
                pg.storage = Some(c.text(a, b).to_string());
            } else if c.kw("TABLESPACE") {
                pg.tablespace = Some(c.ident().ok_or(Fallback)?);
            } else {
                return Err(Fallback);
            }
        }
        let ns = self.namespace(&key.0);
        let id = self.new_id(Kind::Table, &[&key.1]);
        let mut table = Table {
            id: id.clone(),
            namespace: ns,
            name: key.1.clone(),
            comment: None,
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
            options: TableOptions {
                postgres: (pg != PostgresTable::default()).then_some(pg),
                ..TableOptions::default()
            },
        };
        for col in draft.columns {
            let cid = self.new_id(Kind::Column, &[&key.1, &col.name]);
            table.columns.push(Column { id: cid, ..col });
        }
        let col_id = |t: &Table, name: &str| t.columns.iter().find(|c| c.name == name).map(|c| c.id.clone());
        for constraint in draft.constraints {
            match constraint {
                Constraint::Primary { name, columns } => {
                    let cols = columns.iter().map(|n| col_id(&table, n)).collect::<Option<Vec<_>>>().ok_or(Fallback)?;
                    if table.primary_key.is_some() {
                        return Err(Fallback);
                    }
                    table.primary_key = Some(PrimaryKey { name, columns: cols });
                }
                Constraint::Unique { name, columns, nulls_distinct } => {
                    let cols = columns.iter().map(|n| col_id(&table, n)).collect::<Option<Vec<_>>>().ok_or(Fallback)?;
                    let uid = self.new_id(Kind::Key, &[&key.1, name.as_deref().unwrap_or(&columns.join("_"))]);
                    table.uniques.push(Unique { id: uid, name, columns: cols, nulls_distinct });
                }
                Constraint::Check { name, expression } => {
                    let kid = self.new_id(Kind::Check, &[&key.1, name.as_deref().unwrap_or("check")]);
                    table.checks.push(Check { id: kid, name, expression });
                }
                Constraint::Foreign { name, columns, to, to_columns, rest } => {
                    self.pending_fks.push(PendingFk {
                        table: id.clone(),
                        name,
                        columns,
                        to,
                        to_columns,
                        rest,
                        statement: k,
                    });
                }
            }
        }
        self.push_table(table);
        self.relations.insert(key, Rel::Table(self.schema.tables.len() - 1));
        self.modelled(k, &id);
        Ok(())
    }

    fn push_table(&mut self, table: Table) {
        self.schema.tables.push(table);
    }

    /// The columns and table constraints inside `CREATE TABLE … ( … )`.
    fn table_elements(&self, c: &Cur<'_>, from: usize, to: usize) -> Step<Draft> {
        let mut draft = Draft::default();
        for (a, b) in c.commas(from, to) {
            let t = &c.toks()[a].token;
            let is_constraint = ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "EXCLUDE", "LIKE"]
                .iter()
                .any(|kw| is_kw(t, kw));
            if is_constraint {
                draft.constraints.push(constraint(c.st, a, b)?);
            } else {
                let (column, inline) = self.column(c, a, b)?;
                draft.columns.push(column);
                draft.constraints.extend(inline);
            }
        }
        Ok(draft)
    }

    /// One column definition: its name, type and options (inline constraints come back on their own).
    fn column(&self, c: &Cur<'_>, from: usize, to: usize) -> Step<(Column, Vec<Constraint>)> {
        let mut cur = Cur { i: from, ..Cur::new(c.st, Case::FoldLower) };
        let name = cur.ident().ok_or(Fallback)?;
        let type_end = cur.find_top(cur.i, to, is_column_option);
        if type_end == cur.i {
            return Err(Fallback);
        }
        let data_type = types::read(&cur, cur.i, type_end, &self.type_ids);
        cur.i = type_end;
        let mut column = Column {
            id: Id::from_name(Kind::Column, &["pending"]),
            name: name.clone(),
            data_type,
            nullable: true,
            default: None,
            initial_default: None,
            write_default: None,
            generated: None,
            identity: None,
            collation: None,
            comment: None,
            field_id: None,
            on_update: None,
        };
        let mut inline = Vec::new();
        let mut constraint_name: Option<String> = None;
        while cur.i < to {
            if cur.kw("COLLATE") {
                column.collation = Some(cur.ident().ok_or(Fallback)?);
            } else if cur.kws(&["NOT", "NULL"]) {
                column.nullable = false;
            } else if cur.kw("NULL") {
                column.nullable = true;
            } else if cur.kw("DEFAULT") {
                let start = cur.i;
                let end = cur.find_top(start + 1, to, is_column_option);
                column.default = Some(cur.text(start, end).to_string());
                cur.i = end;
            } else if cur.kws(&["GENERATED", "ALWAYS", "AS", "IDENTITY"]) {
                column.identity = Some(Identity { always: true, options: identity_options(&mut cur)? });
            } else if cur.kws(&["GENERATED", "BY", "DEFAULT", "AS", "IDENTITY"]) {
                column.identity = Some(Identity { always: false, options: identity_options(&mut cur)? });
            } else if cur.kws(&["GENERATED", "ALWAYS", "AS"]) {
                let (a, b) = cur.group().ok_or(Fallback)?;
                if !cur.kw("STORED") {
                    return Err(Fallback);
                }
                column.generated = Some(Generated { expression: cur.text(a, b).to_string(), stored: true });
            } else if cur.kw("CONSTRAINT") {
                constraint_name = Some(cur.ident().ok_or(Fallback)?);
            } else if cur.kws(&["PRIMARY", "KEY"]) {
                inline.push(Constraint::Primary { name: constraint_name.take(), columns: vec![name.clone()] });
            } else if cur.kw("UNIQUE") {
                inline.push(Constraint::Unique {
                    name: constraint_name.take(),
                    columns: vec![name.clone()],
                    nulls_distinct: true,
                });
            } else if cur.kw("CHECK") {
                let (a, b) = cur.group().ok_or(Fallback)?;
                inline.push(Constraint::Check { name: constraint_name.take(), expression: cur.text(a, b).to_string() });
            } else if cur.kw("REFERENCES") {
                let to_name = cur.qualified().ok_or(Fallback)?;
                let to_columns = if cur.is(&Token::LParen) { idents(&mut cur)? } else { Vec::new() };
                let rest = fk_rest(&mut cur, to)?;
                inline.push(Constraint::Foreign {
                    name: constraint_name.take(),
                    columns: vec![name.clone()],
                    to: to_name,
                    to_columns,
                    rest,
                });
            } else {
                return Err(Fallback);
            }
        }
        Ok((column, inline))
    }

    fn alter_table(&mut self, c: &mut Cur<'_>, k: usize) -> Step<()> {
        c.kws(&["IF", "EXISTS"]);
        c.kw("ONLY");
        let key = Self::split_name(&c.qualified().ok_or(Fallback)?)?;
        let ti = self.table_index(&key)?;
        let table_id = self.schema.tables[ti].id.clone();
        if c.kws(&["ATTACH", "PARTITION"]) {
            let child_key = Self::split_name(&c.qualified().ok_or(Fallback)?)?;
            let child = self.schema.tables[self.table_index(&child_key)?].id.clone();
            let bounds = c.rest().to_string();
            if !(bounds.starts_with("FOR VALUES") || bounds == "DEFAULT") {
                return Err(Fallback);
            }
            self.attaches.push(Attach { parent: table_id, child: child.clone(), bounds, statement: k });
            self.modelled(k, &child);
            return Ok(());
        }
        if c.kws(&["ALTER", "COLUMN"]) || c.kw("ALTER") {
            let col = c.ident().ok_or(Fallback)?;
            let ci = self.schema.tables[ti].columns.iter().position(|x| x.name == col).ok_or(Fallback)?;
            if c.kws(&["SET", "DEFAULT"]) {
                let text = c.rest().to_string();
                self.schema.tables[ti].columns[ci].default = Some(text);
            } else if c.kws(&["ADD", "GENERATED", "ALWAYS", "AS", "IDENTITY"]) {
                let options = identity_options(c)?;
                if !c.at_end() {
                    return Err(Fallback);
                }
                self.schema.tables[ti].columns[ci].identity = Some(Identity { always: true, options });
            } else if c.kws(&["ADD", "GENERATED", "BY", "DEFAULT", "AS", "IDENTITY"]) {
                let options = identity_options(c)?;
                if !c.at_end() {
                    return Err(Fallback);
                }
                self.schema.tables[ti].columns[ci].identity = Some(Identity { always: false, options });
            } else {
                return Err(Fallback);
            }
            self.modelled(k, &table_id);
            return Ok(());
        }
        if !c.kw("ADD") {
            return Err(Fallback);
        }
        let start = c.i;
        let found = constraint(c.st, start, c.toks().len())?;
        let table_name = self.schema.tables[ti].name.clone();
        let col_id = |s: &Self, n: &str| s.schema.tables[ti].columns.iter().find(|x| x.name == n).map(|x| x.id.clone());
        match found {
            Constraint::Primary { name, columns } => {
                let cols = columns.iter().map(|n| col_id(self, n)).collect::<Option<Vec<_>>>().ok_or(Fallback)?;
                if self.schema.tables[ti].primary_key.is_some() {
                    return Err(Fallback);
                }
                self.schema.tables[ti].primary_key = Some(PrimaryKey { name, columns: cols });
            }
            Constraint::Unique { name, columns, nulls_distinct } => {
                let cols = columns.iter().map(|n| col_id(self, n)).collect::<Option<Vec<_>>>().ok_or(Fallback)?;
                let uid = self.new_id(Kind::Key, &[&table_name, name.as_deref().unwrap_or(&columns.join("_"))]);
                self.schema.tables[ti].uniques.push(Unique { id: uid, name, columns: cols, nulls_distinct });
            }
            Constraint::Check { name, expression } => {
                let kid = self.new_id(Kind::Check, &[&table_name, name.as_deref().unwrap_or("check")]);
                self.schema.tables[ti].checks.push(Check { id: kid, name, expression });
            }
            Constraint::Foreign { name, columns, to, to_columns, rest } => {
                let fk = PendingFk { table: table_id.clone(), name, columns, to, to_columns, rest, statement: k };
                let relationship = self.resolve_fk(&fk).ok_or(Fallback)?;
                let rid = relationship.id.clone();
                self.schema.relationships.push(relationship);
                self.classes[k] = Class::Modelled;
                self.touched.entry(table_id).or_default().push(k);
                self.last = Some(rid);
                return Ok(());
            }
        }
        self.modelled(k, &table_id);
        Ok(())
    }

    fn resolve_fk(&mut self, fk: &PendingFk) -> Option<Relationship> {
        let from = self.schema.tables.iter().find(|t| t.id == fk.table)?;
        let to_key = Self::split_name(&fk.to).ok()?;
        let to = &self.schema.tables[self.table_index(&to_key).ok()?];
        let from_cols: Vec<Id> = fk
            .columns
            .iter()
            .map(|n| from.columns.iter().find(|c| &c.name == n).map(|c| c.id.clone()))
            .collect::<Option<_>>()?;
        let to_cols: Vec<Id> = if fk.to_columns.is_empty() {
            to.primary_key.as_ref()?.columns.clone()
        } else {
            fk.to_columns
                .iter()
                .map(|n| to.columns.iter().find(|c| &c.name == n).map(|c| c.id.clone()))
                .collect::<Option<_>>()?
        };
        let (from_id, to_id, from_name) = (from.id.clone(), to.id.clone(), from.name.clone());
        let label = fk.name.clone().unwrap_or_else(|| format!("{from_name}_{}", fk.columns.join("_")));
        let id = self.new_id(Kind::Relationship, &[&label]);
        let rest = fk.rest.clone();
        Some(Relationship {
            id,
            name: fk.name.clone(),
            from: Ends { table: from_id, columns: from_cols },
            to: Ends { table: to_id, columns: to_cols },
            enforced: true,
            on_delete: rest.on_delete,
            on_update: rest.on_update,
            deferrable: rest.deferrable,
            match_kind: rest.match_kind,
        })
    }

    fn create_index(&mut self, c: &mut Cur<'_>, k: usize) -> Step<()> {
        let unique = c.kw("UNIQUE");
        if !c.kw("INDEX") || c.kw("CONCURRENTLY") || c.kws(&["IF", "NOT", "EXISTS"]) {
            return Err(Fallback);
        }
        let name = c.ident().ok_or(Fallback)?;
        if !c.kw("ON") || c.kw("ONLY") {
            return Err(Fallback);
        }
        let key = Self::split_name(&c.qualified().ok_or(Fallback)?)?;
        let method = if c.kw("USING") { Some(c.ident().ok_or(Fallback)?) } else { None };
        let (a, b) = c.group().ok_or(Fallback)?;
        let columns: Vec<(String, Id)> = match self.relations.get(&key) {
            Some(Rel::Table(i)) => {
                self.schema.tables[*i].columns.iter().map(|x| (x.name.clone(), x.id.clone())).collect()
            }
            Some(Rel::View(_)) => Vec::new(),
            None => return Err(Fallback),
        };
        let on_view = matches!(self.relations.get(&key), Some(Rel::View(_)));
        let mut parts = Vec::new();
        for (x, y) in c.commas(a, b) {
            parts.push(index_part(c, x, y, &columns, on_view)?);
        }
        let mut include = Vec::new();
        if c.kw("INCLUDE") {
            let (x, y) = c.group().ok_or(Fallback)?;
            for (p, q) in c.commas(x, y) {
                let n = ident_of(&c.toks()[p].token, Case::FoldLower).ok_or(Fallback)?;
                if q != p + 1 {
                    return Err(Fallback);
                }
                include.push(columns.iter().find(|(cn, _)| *cn == n).map(|(_, id)| id.clone()).ok_or(Fallback)?);
            }
        }
        let predicate = if c.kw("WHERE") { Some(c.rest().to_string()) } else { None };
        if predicate.is_none() && !c.at_end() {
            return Err(Fallback);
        }
        let id = self.new_id(Kind::Index, &[&name]);
        let index = Index { id: id.clone(), name, unique, parts, method, include, predicate };
        match self.relations.get(&key) {
            Some(Rel::Table(i)) => {
                let i = *i;
                let tid = self.schema.tables[i].id.clone();
                self.schema.tables[i].indexes.push(index);
                self.modelled(k, &tid);
            }
            Some(Rel::View(i)) => {
                let i = *i;
                let view = &mut self.schema.views[i];
                let pg = view.options.postgres.as_mut().ok_or(Fallback)?;
                if !pg.materialized {
                    return Err(Fallback);
                }
                pg.indexes.push(index);
                let vid = view.id.clone();
                self.modelled(k, &vid);
            }
            None => return Err(Fallback),
        }
        Ok(())
    }

    fn create_sequence(&mut self, c: &mut Cur<'_>, k: usize) -> Step<()> {
        c.kw("SEQUENCE");
        if c.kws(&["IF", "NOT", "EXISTS"]) {
            return Err(Fallback);
        }
        let key = Self::split_name(&c.qualified().ok_or(Fallback)?)?;
        let ns = self.namespace(&key.0);
        let mut seq = Sequence {
            id: Id::from_name(Kind::Sequence, &["pending"]),
            namespace: ns,
            name: key.1.clone(),
            data_type: None,
            start: None,
            increment: None,
            min: None,
            max: None,
            cache: None,
            cycle: false,
            owned_by: None,
        };
        while !c.at_end() {
            if c.kw("AS") {
                let start = c.i;
                c.bump();
                seq.data_type = Some(types::read(c, start, c.i, &self.type_ids));
            } else if c.kws(&["START", "WITH"]) || c.kw("START") {
                seq.start = Some(number(c)?);
            } else if c.kws(&["INCREMENT", "BY"]) || c.kw("INCREMENT") {
                seq.increment = Some(number(c)?);
            } else if c.kws(&["NO", "MINVALUE"]) || c.kws(&["NO", "MAXVALUE"]) || c.kws(&["NO", "CYCLE"]) {
            } else if c.kw("MINVALUE") {
                seq.min = Some(number(c)?);
            } else if c.kw("MAXVALUE") {
                seq.max = Some(number(c)?);
            } else if c.kw("CACHE") {
                seq.cache = Some(number(c)?);
            } else if c.kw("CYCLE") {
                seq.cycle = true;
            } else {
                return Err(Fallback);
            }
        }
        seq.id = self.new_id(Kind::Sequence, &[&key.1]);
        let id = seq.id.clone();
        self.schema.sequences.push(seq);
        self.sequences.insert(key, self.schema.sequences.len() - 1);
        self.modelled(k, &id);
        Ok(())
    }

    fn alter_sequence(&mut self, c: &mut Cur<'_>, k: usize) -> Step<()> {
        let key = Self::split_name(&c.qualified().ok_or(Fallback)?)?;
        let si = *self.sequences.get(&key).ok_or(Fallback)?;
        if !c.kws(&["OWNED", "BY"]) {
            return Err(Fallback);
        }
        let parts = c.qualified().ok_or(Fallback)?;
        if !c.at_end() || parts.len() < 2 {
            return Err(Fallback);
        }
        let (table_parts, col) = parts.split_at(parts.len() - 1);
        let tk = Self::split_name(table_parts)?;
        let table = &self.schema.tables[self.table_index(&tk)?];
        let col_id = table.columns.iter().find(|x| x.name == col[0]).map(|x| x.id.clone()).ok_or(Fallback)?;
        self.schema.sequences[si].owned_by = Some(col_id);
        let id = self.schema.sequences[si].id.clone();
        self.modelled(k, &id);
        Ok(())
    }

    fn create_type(&mut self, c: &mut Cur<'_>, k: usize) -> Step<()> {
        c.kw("TYPE");
        let key = Self::split_name(&c.qualified().ok_or(Fallback)?)?;
        if !c.kw("AS") {
            return Err(Fallback);
        }
        let kind = if c.kw("ENUM") {
            let (a, b) = c.group().ok_or(Fallback)?;
            let mut values = Vec::new();
            for (x, y) in c.commas(a, b) {
                if y != x + 1 {
                    return Err(Fallback);
                }
                values.push(string_of(&c.toks()[x].token).ok_or(Fallback)?);
            }
            TypeKind::Enum { values }
        } else if c.is(&Token::LParen) {
            let (a, b) = c.group().ok_or(Fallback)?;
            let mut fields = Vec::new();
            for (x, y) in c.commas(a, b) {
                let name = ident_of(&c.toks()[x].token, Case::FoldLower).ok_or(Fallback)?;
                let collate = c.find_top(x + 1, y, |t| is_kw(t, "COLLATE"));
                if collate != y {
                    return Err(Fallback);
                }
                fields.push(CompositeField { name, data_type: types::read(c, x + 1, y, &self.type_ids) });
            }
            TypeKind::Composite { fields }
        } else {
            return Err(Fallback);
        };
        if !c.at_end() {
            return Err(Fallback);
        }
        self.push_type(k, key, kind);
        Ok(())
    }

    fn create_domain(&mut self, c: &mut Cur<'_>, k: usize) -> Step<()> {
        c.kw("DOMAIN");
        let key = Self::split_name(&c.qualified().ok_or(Fallback)?)?;
        c.kw("AS");
        let start = c.i;
        let end = c.find_top(start, c.toks().len(), |t| {
            ["COLLATE", "DEFAULT", "CONSTRAINT", "NOT", "NULL", "CHECK"].iter().any(|kw| is_kw(t, kw))
        });
        let base = types::read(c, start, end, &self.type_ids);
        c.i = end;
        let (mut default, mut not_null, mut checks) = (None, false, Vec::new());
        while !c.at_end() {
            let begin = c.i;
            if c.kw("DEFAULT") {
                // The expression is at least its first token (`DEFAULT NULL NOT NULL` defaults to NULL).
                if c.at_end() {
                    return Err(Fallback);
                }
                let end = c.find_top(c.i + 1, c.toks().len(), |t| {
                    ["CONSTRAINT", "NOT", "NULL", "CHECK"].iter().any(|kw| is_kw(t, kw))
                });
                default = Some(c.text(c.i, end).to_string());
                c.i = end;
            } else if c.kws(&["NOT", "NULL"]) {
                not_null = true;
            } else if c.is_kw("CONSTRAINT") || c.is_kw("CHECK") {
                if c.kw("CONSTRAINT") {
                    c.ident().ok_or(Fallback)?;
                }
                if !c.kw("CHECK") {
                    return Err(Fallback);
                }
                c.group().ok_or(Fallback)?;
                checks.push(c.text(begin, c.i).to_string());
            } else {
                return Err(Fallback);
            }
        }
        self.push_type(k, key, TypeKind::Domain { base: Box::new(base), default, not_null, checks });
        Ok(())
    }

    fn push_type(&mut self, k: usize, key: (String, String), kind: TypeKind) {
        let ns = self.namespace(&key.0);
        let id = self.new_id(Kind::Type, &[&key.1]);
        self.schema.types.push(TypeDef { id: id.clone(), namespace: ns, name: key.1.clone(), kind, comment: None });
        self.type_ids.insert(key, id.clone());
        self.modelled(k, &id);
    }

    fn create_view(&mut self, c: &mut Cur<'_>, k: usize) -> Step<()> {
        let materialized = c.kw("MATERIALIZED");
        if !c.kw("VIEW") || c.kws(&["IF", "NOT", "EXISTS"]) {
            return Err(Fallback);
        }
        let key = Self::split_name(&c.qualified().ok_or(Fallback)?)?;
        if c.is(&Token::LParen) {
            return Err(Fallback);
        }
        let mut pg = PostgresView { materialized, with_data: true, ..PostgresView::default() };
        if c.kw("WITH") {
            let (a, b) = c.group().ok_or(Fallback)?;
            pg.with = Some(c.text(a, b).to_string());
        }
        if !c.kw("AS") {
            return Err(Fallback);
        }
        let start = c.i;
        let mut end = c.toks().len();
        let toks = c.toks();
        let tail_is = |words: &[&str]| -> bool {
            words.len() <= end - start
                && words.iter().enumerate().all(|(n, w)| is_kw(&toks[end - words.len() + n].token, w))
        };
        if materialized && tail_is(&["WITH", "NO", "DATA"]) {
            pg.with_data = false;
            end -= 3;
        } else if materialized && tail_is(&["WITH", "DATA"]) {
            end -= 2;
        } else if tail_is(&["WITH", "CASCADED", "CHECK", "OPTION"]) {
            pg.check_option = Some("cascaded".to_string());
            end -= 4;
        } else if tail_is(&["WITH", "LOCAL", "CHECK", "OPTION"]) {
            pg.check_option = Some("local".to_string());
            end -= 4;
        } else if tail_is(&["WITH", "CHECK", "OPTION"]) {
            pg.check_option = Some("cascaded".to_string());
            end -= 3;
        }
        let definition = c.text(start, end).to_string();
        let ns = self.namespace(&key.0);
        let id = self.new_id(Kind::View, &[&key.1]);
        let options = if pg == (PostgresView { with_data: true, ..PostgresView::default() }) {
            ViewOptions::default()
        } else {
            ViewOptions { postgres: Some(pg), ..ViewOptions::default() }
        };
        self.schema.views.push(View {
            id: id.clone(),
            namespace: ns,
            name: key.1.clone(),
            comment: None,
            notes: None,
            tags: Vec::new(),
            area: None,
            columns: Vec::new(),
            definition,
            reads: Vec::new(),
            options,
        });
        self.relations.insert(key, Rel::View(self.schema.views.len() - 1));
        self.modelled(k, &id);
        Ok(())
    }

    fn comment(&mut self, c: &mut Cur<'_>, k: usize) -> Step<()> {
        let what = if c.kw("TABLE") {
            "table"
        } else if c.kws(&["MATERIALIZED", "VIEW"]) || c.kw("VIEW") {
            "view"
        } else if c.kw("COLUMN") {
            "column"
        } else if c.kw("SCHEMA") {
            "schema"
        } else if c.kw("TYPE") || c.kw("DOMAIN") {
            "type"
        } else {
            return Err(Fallback);
        };
        let parts = c.qualified().ok_or(Fallback)?;
        if !c.kw("IS") {
            return Err(Fallback);
        }
        let text = if c.kw("NULL") { None } else { Some(string_of(&c.bump().ok_or(Fallback)?.token).ok_or(Fallback)?) };
        if !c.at_end() {
            return Err(Fallback);
        }
        let touched = match what {
            "table" | "view" => {
                let key = Self::split_name(&parts)?;
                match (what, self.relations.get(&key)) {
                    ("table", Some(Rel::Table(i))) => {
                        let t = &mut self.schema.tables[*i];
                        t.comment = text;
                        t.id.clone()
                    }
                    ("view", Some(Rel::View(i))) => {
                        let v = &mut self.schema.views[*i];
                        v.comment = text;
                        v.id.clone()
                    }
                    _ => return Err(Fallback),
                }
            }
            "column" => {
                if parts.len() < 2 {
                    return Err(Fallback);
                }
                let (rel, col) = parts.split_at(parts.len() - 1);
                let key = Self::split_name(rel)?;
                let ti = self.table_index(&key)?;
                let t = &mut self.schema.tables[ti];
                let column = t.columns.iter_mut().find(|x| x.name == col[0]).ok_or(Fallback)?;
                column.comment = text;
                t.id.clone()
            }
            "schema" => {
                let [name] = parts.as_slice() else { return Err(Fallback) };
                let id = self.namespaces.get(name).cloned().ok_or(Fallback)?;
                let ns = self.schema.namespaces.iter_mut().find(|n| n.id == id).ok_or(Fallback)?;
                ns.comment = text;
                id
            }
            _ => {
                let key = Self::split_name(&parts)?;
                let id = self.type_ids.get(&key).cloned().ok_or(Fallback)?;
                let ty = self.schema.types.iter_mut().find(|t| t.id == id).ok_or(Fallback)?;
                ty.comment = text;
                id
            }
        };
        self.modelled(k, &touched);
        Ok(())
    }

    /// After every statement: foreign keys declared before their target, view dependencies, partition series,
    /// what kept statements refer to.
    fn finish(&mut self) {
        for fk in std::mem::take(&mut self.pending_fks) {
            match self.resolve_fk(&fk) {
                Some(rel) => self.schema.relationships.push(rel),
                None => {
                    let line = self.statements[fk.statement].line;
                    self.not_understood
                        .push((line, format!("a foreign key of `{}` to a table not in the dump", fk.table)));
                }
            }
        }
        self.view_reads();
        self.partitions();
        self.kept_refers_to();
    }

    fn view_reads(&mut self) {
        for vi in 0..self.schema.views.len() {
            let definition = self.schema.views[vi].definition.clone();
            let Ok(parsed) = sqlparser::parser::Parser::parse_sql(&PostgreSqlDialect {}, &definition) else {
                continue;
            };
            let names: Vec<(String, String)> =
                crate::relations_in(&parsed, true).iter().filter_map(|parts| Self::split_name(parts).ok()).collect();
            let mut reads = Vec::new();
            for key in names {
                let id = match self.relations.get(&key) {
                    Some(Rel::Table(i)) => self.schema.tables[*i].id.clone(),
                    Some(Rel::View(i)) => self.schema.views[*i].id.clone(),
                    None => continue,
                };
                if !reads.contains(&id) && id != self.schema.views[vi].id {
                    reads.push(id);
                }
            }
            self.schema.views[vi].reads = reads;
        }
    }

    /// Attached partitions: a run of daily or monthly ones becomes a series, kept verbatim; the rest are designed
    /// partitions, tables of their own.
    fn partitions(&mut self) {
        let attaches = std::mem::take(&mut self.attaches);
        // Each parent once, in the order first seen, however its attaches are interleaved with others'.
        let parents: Vec<Id> = {
            let mut p: Vec<Id> = Vec::new();
            for a in &attaches {
                if !p.contains(&a.parent) {
                    p.push(a.parent.clone());
                }
            }
            p
        };
        // Each folded child, and the parent whose series it went into.
        let mut gone: HashMap<Id, Id> = HashMap::new();
        for parent in parents {
            let mine: Vec<&Attach> = attaches.iter().filter(|a| a.parent == parent).collect();
            let run = series(&mine);
            if run.len() >= SERIES_MIN {
                self.collapse(&parent, &run, &mut gone);
            }
            for a in mine.iter().filter(|a| !gone.contains_key(&a.child)) {
                if self.has_own(&a.child) {
                    // Keys, constraints, indexes, links or sequences of its own name its columns: it stays a table
                    // with them, and its ATTACH is kept as written, after both, as pg_dump lays it out.
                    self.keep_attach(a);
                } else if let Some(t) = self.schema.tables.iter_mut().find(|t| t.id == a.child) {
                    t.partition_of = Some(PartitionOf { parent: parent.clone(), bounds: a.bounds.clone() });
                    t.columns.clear();
                }
            }
        }
        if !gone.is_empty() {
            self.forget_folded(&gone);
            self.schema.tables.retain(|t| !gone.contains_key(&t.id));
            let tables = &self.schema.tables;
            self.relations.retain(|_, r| !matches!(r, Rel::Table(_)));
            for (i, t) in tables.iter().enumerate() {
                let ns = self.schema.namespaces.iter().find(|n| n.id == t.namespace).map(|n| n.name.clone());
                if let Some(ns) = ns {
                    self.relations.insert((ns, t.name.clone()), Rel::Table(i));
                }
            }
        }
    }

    /// Whether a table has anything of its own that names its columns.
    fn has_own(&self, id: &Id) -> bool {
        let Some(t) = self.schema.tables.iter().find(|t| &t.id == id) else { return false };
        let cols: HashSet<&Id> = t.columns.iter().map(|c| &c.id).collect();
        t.primary_key.is_some()
            || !t.uniques.is_empty()
            || !t.checks.is_empty()
            || !t.indexes.is_empty()
            || self.schema.relationships.iter().any(|r| &r.from.table == id || &r.to.table == id)
            || self.schema.sequences.iter().any(|q| q.owned_by.as_ref().is_some_and(|c| cols.contains(c)))
    }

    /// Keeps an attached partition's ATTACH statement as written, after the later of the parent and the child.
    fn keep_attach(&mut self, a: &Attach) {
        let at = |id: &Id| self.schema.tables.iter().position(|t| &t.id == id);
        let after = if at(&a.parent) > at(&a.child) { a.parent.clone() } else { a.child.clone() };
        let id = self.new_id(Kind::Kept, &["attach", a.child.as_str()]);
        self.classes[a.statement] = Class::Kept(KeptKind::Partitions);
        self.kept_from.insert(id.clone(), a.statement);
        self.schema.kept.push(Kept {
            id,
            kind: KeptKind::Partitions,
            text: self.statements[a.statement].text.clone(),
            after: Some(after),
            refers_to: vec![a.parent.clone(), a.child.clone()],
        });
    }

    /// After children are folded into a series (`gone`: each child and its parent): what pointed at them no longer
    /// points at nothing.
    fn forget_folded(&mut self, gone: &HashMap<Id, Id>) {
        // Links from a folded child travel in the series text; a link to one is reported, not kept half.
        let mut lost = Vec::new();
        self.schema.relationships.retain(|r| {
            if gone.contains_key(&r.to.table) && !gone.contains_key(&r.from.table) {
                lost.push(r.name.clone().unwrap_or_else(|| r.id.to_string()));
            }
            !gone.contains_key(&r.from.table) && !gone.contains_key(&r.to.table)
        });
        for name in lost {
            self.not_understood.push((0, format!("foreign key `{name}` points at a partition folded into a series")));
        }
        for v in &mut self.schema.views {
            v.reads.retain(|r| !gone.contains_key(r));
        }
        // A sequence owned by a folded child's column keeps its OWNED BY as written, after the parent's series.
        let ns_name = |s: &Self, id: &Id| {
            s.schema.namespaces.iter().find(|n| &n.id == id).map_or(String::new(), |n| n.name.clone())
        };
        let mut owned = Vec::new();
        for (qi, q) in self.schema.sequences.iter().enumerate() {
            let Some(col) = &q.owned_by else { continue };
            let Some(t) =
                self.schema.tables.iter().find(|t| gone.contains_key(&t.id) && t.columns.iter().any(|c| &c.id == col))
            else {
                continue;
            };
            let c = t.columns.iter().find(|c| &c.id == col).expect("found");
            let text = format!(
                "ALTER SEQUENCE \"{}\".\"{}\" OWNED BY \"{}\".\"{}\".\"{}\"",
                ns_name(self, &q.namespace),
                q.name,
                ns_name(self, &t.namespace),
                t.name,
                c.name
            );
            owned.push((qi, text, gone[&t.id].clone()));
        }
        for (qi, text, parent) in owned {
            self.schema.sequences[qi].owned_by = None;
            let id = self.new_id(Kind::Kept, &["owned", &self.schema.sequences[qi].name.clone()]);
            self.schema.kept.push(Kept {
                id,
                kind: KeptKind::Other,
                text,
                after: Some(parent.clone()),
                refers_to: vec![parent],
            });
        }
        // Kept statements placed after a folded child go after its parent, where the series is written.
        for k in &mut self.schema.kept {
            if let Some(parent) = k.after.as_ref().and_then(|a| gone.get(a)) {
                k.after = Some(parent.clone());
            }
        }
    }

    fn collapse(&mut self, parent: &Id, run: &[(&Attach, String, String)], gone: &mut HashMap<Id, Id>) {
        let children: HashSet<Id> = run.iter().map(|(a, _, _)| a.child.clone()).collect();
        let mut statements: Vec<usize> = Vec::new();
        for (a, _, _) in run {
            statements.extend(self.touched.get(&a.child).into_iter().flatten().copied());
            statements.push(a.statement);
        }
        // Kept statements about a child (its owner, its grants) go with it.
        let names: HashSet<String> = run
            .iter()
            .filter_map(|(a, _, _)| self.schema.tables.iter().find(|t| t.id == a.child))
            .map(|t| t.name.clone())
            .collect();
        let mut moved_kept = Vec::new();
        for kept in &self.schema.kept {
            let k = self.kept_from[&kept.id];
            let mentions = self.statements[k]
                .tokens
                .iter()
                .any(|t| ident_of(&t.token, Case::FoldLower).is_some_and(|n| names.contains(&n)));
            if mentions {
                statements.push(k);
                moved_kept.push(kept.id.clone());
            }
        }
        statements.sort_unstable();
        statements.dedup();
        self.schema.kept.retain(|k| !moved_kept.contains(&k.id));
        let text = statements.iter().map(|k| self.statements[*k].text.as_str()).collect::<Vec<_>>().join(";\n\n");
        let id = self.new_id(Kind::Kept, &["partitions", &format!("{parent}")]);
        for k in &statements {
            self.classes[*k] = Class::Kept(KeptKind::Partitions);
        }
        self.kept_from.insert(id.clone(), statements[0]);
        self.schema.kept.push(Kept {
            id: id.clone(),
            kind: KeptKind::Partitions,
            text,
            after: Some(parent.clone()),
            refers_to: vec![parent.clone()],
        });
        let (first, last) = (run[0].1.clone(), run[run.len() - 1].2.clone());
        let interval = interval_of(&run[0].1, &run[0].2).unwrap_or_default();
        if let Some(t) = self.schema.tables.iter_mut().find(|t| &t.id == parent) {
            let pg = t.options.postgres.get_or_insert_with(PostgresTable::default);
            let policy = pg.partition_policy.get_or_insert_with(PartitionPolicy::default);
            policy.series = Some(PartitionSeries {
                interval,
                first,
                last,
                count: u32::try_from(run.len()).unwrap_or(u32::MAX),
                kept: id,
            });
        }
        gone.extend(children.into_iter().map(|c| (c, parent.clone())));
        self.series += 1;
    }

    /// What each kept statement names, by qualified name.
    fn kept_refers_to(&mut self) {
        let mut names: HashMap<(String, String), Id> = HashMap::new();
        let ns_name =
            |id: &Id, namespaces: &[Namespace]| namespaces.iter().find(|n| &n.id == id).map(|n| n.name.clone());
        for t in &self.schema.tables {
            if let Some(ns) = ns_name(&t.namespace, &self.schema.namespaces) {
                names.insert((ns, t.name.clone()), t.id.clone());
            }
        }
        for v in &self.schema.views {
            if let Some(ns) = ns_name(&v.namespace, &self.schema.namespaces) {
                names.insert((ns, v.name.clone()), v.id.clone());
            }
        }
        for kept in &mut self.schema.kept {
            if kept.kind == KeptKind::Partitions {
                continue;
            }
            let Some(&k) = self.kept_from.get(&kept.id) else { continue };
            let toks = &self.statements[k].tokens;
            for w in toks.windows(3) {
                if w[1].token != Token::Period {
                    continue;
                }
                let (Some(a), Some(b)) =
                    (ident_of(&w[0].token, Case::FoldLower), ident_of(&w[2].token, Case::FoldLower))
                else {
                    continue;
                };
                if let Some(id) = names.get(&(a, b))
                    && !kept.refers_to.contains(id)
                {
                    kept.refers_to.push(id.clone());
                }
            }
        }
    }
}

#[derive(Default)]
struct Draft {
    columns: Vec<Column>,
    constraints: Vec<Constraint>,
}

enum Constraint {
    Primary { name: Option<String>, columns: Vec<String> },
    Unique { name: Option<String>, columns: Vec<String>, nulls_distinct: bool },
    Check { name: Option<String>, expression: String },
    Foreign { name: Option<String>, columns: Vec<String>, to: Vec<String>, to_columns: Vec<String>, rest: FkRest },
}

/// A table constraint in tokens `from..to`: `[CONSTRAINT name] PRIMARY KEY (…)`, `UNIQUE`, `CHECK`, `FOREIGN KEY`.
fn constraint(st: &Statement, from: usize, to: usize) -> Step<Constraint> {
    let mut c = Cur { i: from, ..Cur::new(st, Case::FoldLower) };
    let name = if c.kw("CONSTRAINT") { Some(c.ident().ok_or(Fallback)?) } else { None };
    let found = if c.kws(&["PRIMARY", "KEY"]) {
        Constraint::Primary { name, columns: idents(&mut c)? }
    } else if c.kw("UNIQUE") {
        let nulls_distinct = !c.kws(&["NULLS", "NOT", "DISTINCT"]);
        c.kws(&["NULLS", "DISTINCT"]);
        Constraint::Unique { name, columns: idents(&mut c)?, nulls_distinct }
    } else if c.kw("CHECK") {
        let (a, b) = c.group().ok_or(Fallback)?;
        Constraint::Check { name, expression: c.text(a, b).to_string() }
    } else if c.kws(&["FOREIGN", "KEY"]) {
        let columns = idents(&mut c)?;
        if !c.kw("REFERENCES") {
            return Err(Fallback);
        }
        let to_name = c.qualified().ok_or(Fallback)?;
        let to_columns = if c.is(&Token::LParen) { idents(&mut c)? } else { Vec::new() };
        let rest = fk_rest(&mut c, to)?;
        Constraint::Foreign { name, columns, to: to_name, to_columns, rest }
    } else {
        return Err(Fallback);
    };
    if c.i != to {
        return Err(Fallback);
    }
    Ok(found)
}

/// `(a, b, c)`: plain column names only.
fn idents(c: &mut Cur<'_>) -> Step<Vec<String>> {
    let (a, b) = c.group().ok_or(Fallback)?;
    let mut out = Vec::new();
    for (x, y) in c.commas(a, b) {
        if y != x + 1 {
            return Err(Fallback);
        }
        out.push(ident_of(&c.toks()[x].token, Case::FoldLower).ok_or(Fallback)?);
    }
    Ok(out)
}

/// What follows `REFERENCES t (…)`, up to token `to`.
fn fk_rest(c: &mut Cur<'_>, to: usize) -> Step<FkRest> {
    let mut rest = FkRest::default();
    while c.i < to {
        if c.kws(&["ON", "DELETE"]) {
            rest.on_delete = Some(action(c)?);
        } else if c.kws(&["ON", "UPDATE"]) {
            rest.on_update = Some(action(c)?);
        } else if c.kw("MATCH") {
            rest.match_kind = Some(c.ident().ok_or(Fallback)?.to_uppercase());
        } else if c.is_kw("DEFERRABLE") || c.is_kw("NOT") && c.is_kw_at(1, "DEFERRABLE") {
            let start = c.i;
            c.kw("NOT");
            c.kw("DEFERRABLE");
            if c.kw("INITIALLY") {
                c.bump();
            }
            rest.deferrable = Some(c.text(start, c.i).to_string());
        } else {
            return Err(Fallback);
        }
    }
    Ok(rest)
}

fn action(c: &mut Cur<'_>) -> Step<Action> {
    Ok(if c.kws(&["NO", "ACTION"]) {
        Action::NoAction
    } else if c.kw("RESTRICT") {
        Action::Restrict
    } else if c.kw("CASCADE") {
        Action::Cascade
    } else if c.kws(&["SET", "NULL"]) {
        if c.is(&Token::LParen) {
            return Err(Fallback);
        }
        Action::SetNull
    } else if c.kws(&["SET", "DEFAULT"]) {
        if c.is(&Token::LParen) {
            return Err(Fallback);
        }
        Action::SetDefault
    } else {
        return Err(Fallback);
    })
}

/// `( SEQUENCE NAME … START WITH … )` after `AS IDENTITY`, kept as written; none when absent.
fn identity_options(c: &mut Cur<'_>) -> Step<Option<String>> {
    if !c.is(&Token::LParen) {
        return Ok(None);
    }
    let (a, b) = c.group().ok_or(Fallback)?;
    Ok(Some(c.text(a, b).trim().to_string()))
}

fn number(c: &mut Cur<'_>) -> Step<i64> {
    let negative = c.eat(&Token::Minus);
    match &c.bump().ok_or(Fallback)?.token {
        Token::Number(n, _) => n.parse::<i64>().map(|v| if negative { -v } else { v }).map_err(|_| Fallback),
        _ => Err(Fallback),
    }
}

/// One part of an index's column list: a column, or an expression, with its order.
/// On a materialized view, whose columns carry no ids, a column is held as an expression naming it.
fn index_part(c: &Cur<'_>, from: usize, to: usize, columns: &[(String, Id)], on_view: bool) -> Step<IndexPart> {
    let toks = c.toks();
    let mut end = to;
    let mut nulls = None;
    let mut direction = None;
    if end >= from + 2 && is_kw(&toks[end - 2].token, "NULLS") {
        nulls = Some(if is_kw(&toks[end - 1].token, "FIRST") { Nulls::First } else { Nulls::Last });
        end -= 2;
    }
    if end > from && (is_kw(&toks[end - 1].token, "ASC") || is_kw(&toks[end - 1].token, "DESC")) {
        direction = Some(if is_kw(&toks[end - 1].token, "ASC") { Direction::Asc } else { Direction::Desc });
        end -= 1;
    }
    if end == from + 1 && on_view {
        ident_of(&toks[from].token, Case::FoldLower).ok_or(Fallback)?;
        return Ok(IndexPart {
            column: None,
            expression: Some(c.text(from, end).to_string()),
            direction,
            nulls,
            length: None,
        });
    }
    if end == from + 1 {
        let name = ident_of(&toks[from].token, Case::FoldLower).ok_or(Fallback)?;
        let id = columns.iter().find(|(n, _)| *n == name).map(|(_, id)| id.clone()).ok_or(Fallback)?;
        return Ok(IndexPart { column: Some(id), expression: None, direction, nulls, length: None });
    }
    // A function call or a parenthesised expression; a column with an operator class or collation is not one.
    let looks_like_expression = matches!(toks[from].token, Token::LParen)
        || (toks.get(from + 1).is_some_and(|t| t.token == Token::LParen) && c.matching(from + 1) == Some(end - 1));
    if !looks_like_expression {
        return Err(Fallback);
    }
    Ok(IndexPart { column: None, expression: Some(c.text(from, end).to_string()), direction, nulls, length: None })
}

/// Whether a token starts a column option: where a column's type, or a default, ends.
fn is_column_option(t: &Token) -> bool {
    ["COLLATE", "NOT", "NULL", "DEFAULT", "GENERATED", "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "REFERENCES"]
        .iter()
        .any(|kw| is_kw(t, kw))
}

/// `ALTER … OWNER TO …`.
fn owner_to(st: &Statement) -> bool {
    let toks = &st.tokens;
    is_kw(&toks[0].token, "ALTER") && toks.windows(2).any(|w| is_kw(&w[0].token, "OWNER") && is_kw(&w[1].token, "TO"))
}

/// The longest run of attaches whose bounds step by one day or one month, back to back, with their first and last
/// bounds.
fn series<'a>(attaches: &[&'a Attach]) -> Vec<(&'a Attach, String, String)> {
    let mut ranged: Vec<(&Attach, String, String)> =
        attaches.iter().filter_map(|a| range_bounds(&a.bounds).map(|(f, t)| (*a, f, t))).collect();
    ranged.sort_by(|a, b| a.1.cmp(&b.1));
    let mut best: Vec<(&Attach, String, String)> = Vec::new();
    let mut current: Vec<(&Attach, String, String)> = Vec::new();
    let mut step: Option<String> = None;
    for item in ranged {
        let this_step = interval_of(&item.1, &item.2);
        let continues = current.last().is_some_and(|prev| prev.2 == item.1) && this_step.is_some() && this_step == step;
        if !continues {
            if current.len() > best.len() {
                best = std::mem::take(&mut current);
            }
            current.clear();
            step = this_step;
        }
        if step.is_some() {
            current.push(item);
        }
    }
    if current.len() > best.len() {
        best = current;
    }
    best
}

/// `FOR VALUES FROM ('2025-01-01') TO ('2025-01-02')` as its two dates.
fn range_bounds(bounds: &str) -> Option<(String, String)> {
    let rest = bounds.strip_prefix("FOR VALUES FROM ('")?;
    let (from, rest) = rest.split_once("') TO ('")?;
    let to = rest.strip_suffix("')")?;
    Some((from.to_string(), to.to_string()))
}

/// `1 day` or `1 month` when `to` is exactly that after `from` (dates written `YYYY-MM-DD`).
fn interval_of(from: &str, to: &str) -> Option<String> {
    let (fy, fm, fd) = ymd(from)?;
    let (ty, tm, td) = ymd(to)?;
    if days(ty, tm, td) - days(fy, fm, fd) == 1 {
        return Some("1 day".to_string());
    }
    let next = if fm == 12 { (fy + 1, 1) } else { (fy, fm + 1) };
    (fd == 1 && td == 1 && (ty, tm) == next).then(|| "1 month".to_string())
}

fn ymd(s: &str) -> Option<(i64, i64, i64)> {
    let date = s.get(..10)?;
    if s.len() > 10 && !s[10..].trim_start_matches([' ', 'T']).starts_with("00:00") {
        return None;
    }
    let mut parts = date.split('-');
    let y = parts.next()?.parse().ok()?;
    let m = parts.next()?.parse().ok()?;
    let d = parts.next()?.parse().ok()?;
    Some((y, m, d))
}

/// Days since a fixed epoch (proleptic Gregorian), for counting days between dates.
fn days(y: i64, m: i64, d: i64) -> i64 {
    let (y, m) = if m <= 2 { (y - 1, m + 9) } else { (y, m - 3) };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * m + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn intervals_are_days_or_months() {
        assert_eq!(interval_of("2025-01-31", "2025-02-01").as_deref(), Some("1 day"));
        assert_eq!(interval_of("2024-02-28", "2024-02-29").as_deref(), Some("1 day"));
        assert_eq!(interval_of("2025-12-01", "2026-01-01").as_deref(), Some("1 month"));
        assert_eq!(interval_of("2025-01-01", "2025-01-03"), None);
        assert_eq!(interval_of("2025-01-01 00:00:00", "2025-01-02 00:00:00").as_deref(), Some("1 day"));
    }
}
