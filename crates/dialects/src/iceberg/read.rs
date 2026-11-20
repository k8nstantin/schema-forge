//! Reading Iceberg tables and views written in Spark SQL, from one file or a folder of them.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use schema_forge_core::{
    Column, Direction, IcebergTable, IcebergView, Id, Kept, KeptKind, Kind, Namespace, Nulls, PartitionField, Schema,
    SortField, Table, TableOptions, Target, View, ViewOptions,
};
use sqlparser::dialect::DatabricksDialect;
use sqlparser::tokenizer::Token;

use crate::cursor::{Case, Cur, ident_of, is_kw, string_of};
use crate::report::{Imported, Report};
use crate::split::{Statement, Tok, split};

use super::types;

/// What stops Iceberg DDL from being read at all.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Split(#[from] crate::split::SplitError),
    #[error("{path}: {source}")]
    File { path: PathBuf, source: std::io::Error },
}

struct Fallback;
type Step<T> = Result<T, Fallback>;

/// Reads Spark SQL Iceberg DDL from one text.
///
/// # Errors
/// When the text cannot be cut into statements.
pub fn import(text: &str) -> Result<Imported, Error> {
    let mut r = Reader::default();
    r.read(text)?;
    Ok(r.done())
}

/// Reads every `.sql` file under `dir`, in path order: one table (or view) per file, as a catalog export lays them out
/// (`<catalog>/<namespace>/<table>.sql`), or any mix.
///
/// # Errors
/// When a file cannot be read or cut into statements.
pub fn import_folder(dir: &Path) -> Result<Imported, Error> {
    let mut files = Vec::new();
    collect(dir, &mut files)?;
    files.sort();
    let mut r = Reader::default();
    for path in files {
        let text = std::fs::read_to_string(&path).map_err(|source| Error::File { path: path.clone(), source })?;
        r.read(&text)?;
    }
    Ok(r.done())
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), Error> {
    let entries = std::fs::read_dir(dir).map_err(|source| Error::File { path: dir.to_path_buf(), source })?;
    for entry in entries {
        let path = entry.map_err(|source| Error::File { path: dir.to_path_buf(), source })?.path();
        if path.is_dir() {
            collect(&path, out)?;
        } else if path.extension().is_some_and(|e| e == "sql") {
            out.push(path);
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy)]
enum Rel {
    Table(usize),
    View(usize),
}

struct Reader {
    schema: Schema,
    report: Report,
    ids: HashSet<Id>,
    namespaces: HashMap<Vec<String>, Id>,
    relations: HashMap<Vec<String>, Rel>,
    last: Option<Id>,
}

impl Default for Reader {
    fn default() -> Self {
        Self {
            schema: Schema::new(Target::Iceberg),
            report: Report::default(),
            ids: HashSet::new(),
            namespaces: HashMap::new(),
            relations: HashMap::new(),
            last: None,
        }
    }
}

impl Reader {
    fn read(&mut self, text: &str) -> Result<(), Error> {
        let split = split(&DatabricksDialect {}, text)?;
        self.report.statements += split.statements.len() + split.copy_blocks;
        self.report.data += split.copy_blocks;
        for st in &split.statements {
            self.statement(st);
        }
        Ok(())
    }

    fn done(mut self) -> Imported {
        self.view_reads();
        Imported { schema: self.schema, report: self.report }
    }

    /// What each view reads, from its definition: tables and views by their full names.
    fn view_reads(&mut self) {
        for vi in 0..self.schema.views.len() {
            let Ok(parsed) =
                sqlparser::parser::Parser::parse_sql(&DatabricksDialect {}, &self.schema.views[vi].definition)
            else {
                continue;
            };
            let mut names: Vec<Vec<String>> = Vec::new();
            let _ = sqlparser::ast::visit_relations(&parsed, |name| {
                names.push(name.0.iter().filter_map(|p| p.as_ident()).map(|i| i.value.clone()).collect());
                std::ops::ControlFlow::<()>::Continue(())
            });
            let mut reads = Vec::new();
            for n in names {
                let id = match self.relations.get(&n) {
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

    fn statement(&mut self, st: &Statement) {
        let mut c = Cur::new(st, Case::Keep);
        let done = if c.kws(&["CREATE", "TABLE"]) {
            self.create_table(&mut c, st)
        } else if c.kws(&["CREATE", "VIEW"]) || c.kws(&["CREATE", "OR", "REPLACE", "VIEW"]) {
            self.create_view(&mut c, st)
        } else if c.kws(&["ALTER", "TABLE"]) {
            self.alter_table(&mut c, st)
        } else {
            Err(Fallback)
        };
        match done {
            Ok(()) => self.report.modelled += 1,
            Err(Fallback) => self.keep(st),
        }
    }

    fn keep(&mut self, st: &Statement) {
        let first: String = st.text.split_whitespace().take(6).collect::<Vec<_>>().join(" ");
        self.report.not_understood.push((st.line, first));
        *self.report.kept.entry("other".to_string()).or_default() += 1;
        let id = self.new_id(Kind::Kept, &[&(self.schema.kept.len() + 1).to_string()]);
        let text = if st.leading.is_empty() { st.text.clone() } else { format!("{}\n{}", st.leading, st.text) };
        self.schema.kept.push(Kept {
            id,
            kind: KeptKind::Other,
            text,
            after: self.last.clone(),
            refers_to: Vec::new(),
        });
    }

    /// The namespace chain for `path` (all but the last part of a name), made as needed.
    fn namespace(&mut self, path: &[String]) -> Step<Id> {
        if path.is_empty() {
            return Err(Fallback);
        }
        if let Some(id) = self.namespaces.get(path) {
            return Ok(id.clone());
        }
        let parent = if path.len() > 1 { Some(self.namespace(&path[..path.len() - 1])?) } else { None };
        let name = path[path.len() - 1].clone();
        let slug: Vec<&str> = path.iter().map(String::as_str).collect();
        let id = self.new_id(Kind::Namespace, &slug);
        self.schema.namespaces.push(Namespace { id: id.clone(), name, parent, comment: None });
        self.namespaces.insert(path.to_vec(), id.clone());
        Ok(id)
    }

    fn create_table(&mut self, c: &mut Cur<'_>, st: &Statement) -> Step<()> {
        c.kws(&["IF", "NOT", "EXISTS"]);
        let name = c.qualified().ok_or(Fallback)?;
        if name.len() < 2 || self.relations.contains_key(&name) {
            return Err(Fallback);
        }
        let (from, to) = c.group().ok_or(Fallback)?;
        let table_name = name[name.len() - 1].clone();
        let mut columns: Vec<(String, schema_forge_core::DataType, bool, Option<String>)> = Vec::new();
        for (a, b) in commas(c, from, to) {
            columns.push(column(c, a, b)?);
        }
        let mut ice = IcebergTable::default();
        let mut comment = None;
        let mut partition_names: Vec<(String, String)> = Vec::new();
        while !c.at_end() {
            if c.kw("USING") {
                let provider = c.ident().ok_or(Fallback)?;
                if !provider.eq_ignore_ascii_case("iceberg") {
                    return Err(Fallback);
                }
            } else if c.kws(&["PARTITIONED", "BY"]) {
                let (a, b) = c.group().ok_or(Fallback)?;
                for (x, y) in c.commas(a, b) {
                    partition_names.push(partition_item(c, x, y)?);
                }
            } else if c.kw("LOCATION") {
                ice.location = Some(string_of(&c.bump().ok_or(Fallback)?.token).ok_or(Fallback)?);
            } else if c.kw("COMMENT") {
                comment = Some(string_of(&c.bump().ok_or(Fallback)?.token).ok_or(Fallback)?);
            } else if c.kw("TBLPROPERTIES") {
                properties(c, &mut ice.properties)?;
            } else {
                return Err(Fallback);
            }
        }
        if let Some(v) = ice.properties.remove("format-version") {
            ice.format_version = Some(v.parse().map_err(|_| Fallback)?);
        }
        let namespace = self.namespace(&name[..name.len() - 1])?;
        let id = self.new_id(Kind::Table, &[&table_name]);
        let mut table_columns = Vec::new();
        let mut next = i32::try_from(columns.len()).map_err(|_| Fallback)? + 1;
        for (n, (col, mut data_type, nullable, comment)) in columns.into_iter().enumerate() {
            types::assign_ids(&mut data_type, &mut next);
            let cid = self.new_id(Kind::Column, &[&table_name, &col]);
            table_columns.push(Column {
                id: cid,
                name: col,
                data_type,
                nullable,
                default: None,
                initial_default: None,
                write_default: None,
                generated: None,
                identity: None,
                collation: None,
                comment,
                field_id: Some(i32::try_from(n).map_err(|_| Fallback)? + 1),
                on_update: None,
            });
        }
        for (transform, col) in partition_names {
            let source = table_columns.iter().find(|c| c.name == col).map(|c| c.id.clone()).ok_or(Fallback)?;
            ice.partition_spec.push(PartitionField { source, transform, name: None });
        }
        self.schema.tables.push(Table {
            id: id.clone(),
            namespace,
            name: table_name,
            comment,
            notes: notes(&st.leading),
            tags: Vec::new(),
            area: None,
            columns: table_columns,
            primary_key: None,
            uniques: Vec::new(),
            checks: Vec::new(),
            indexes: Vec::new(),
            patterns: BTreeMap::new(),
            partition_of: None,
            options: TableOptions { iceberg: Some(ice), ..TableOptions::default() },
        });
        self.relations.insert(name, Rel::Table(self.schema.tables.len() - 1));
        self.last = Some(id);
        Ok(())
    }

    fn alter_table(&mut self, c: &mut Cur<'_>, st: &Statement) -> Step<()> {
        let name = c.qualified().ok_or(Fallback)?;
        let Some(Rel::Table(ti)) = self.relations.get(&name).copied() else { return Err(Fallback) };
        let col_id = |s: &Self, n: &str| s.schema.tables[ti].columns.iter().find(|c| c.name == n).map(|c| c.id.clone());
        if c.kws(&["WRITE", "ORDERED", "BY"]) {
            let (a, b) = if c.is(&Token::LParen) { c.group().ok_or(Fallback)? } else { (c.i, c.toks().len()) };
            let mut order = Vec::new();
            for (x, y) in c.commas(a, b) {
                let mut item = Cur { i: x, ..Cur::new(c.st, Case::Keep) };
                let (transform, col) = if item.toks()[x + 1..y].first().is_some_and(|t| t.token == Token::LParen) {
                    let close = item.matching(x + 1).ok_or(Fallback)?;
                    let found = partition_item(&item, x, close + 1)?;
                    item.i = close + 1;
                    found
                } else {
                    ("identity".to_string(), item.ident().ok_or(Fallback)?)
                };
                let direction = if item.kw("DESC") {
                    Direction::Desc
                } else {
                    item.kw("ASC");
                    Direction::Asc
                };
                // Without `NULLS …`, Iceberg puts nulls first when ascending, last when descending.
                let nulls = if item.kws(&["NULLS", "LAST"]) {
                    Nulls::Last
                } else if item.kws(&["NULLS", "FIRST"]) || direction == Direction::Asc {
                    Nulls::First
                } else {
                    Nulls::Last
                };
                if item.i != y {
                    return Err(Fallback);
                }
                order.push(SortField { source: col_id(self, &col).ok_or(Fallback)?, transform, direction, nulls });
            }
            c.i = c.toks().len();
            self.ice(ti).sort_order = order;
        } else if c.kws(&["SET", "IDENTIFIER", "FIELDS"]) {
            let mut fields = Vec::new();
            loop {
                let n = c.ident().ok_or(Fallback)?;
                fields.push(col_id(self, &n).ok_or(Fallback)?);
                if !c.eat(&Token::Comma) {
                    break;
                }
            }
            self.ice(ti).identifier_fields = fields;
        } else if c.kws(&["SET", "TBLPROPERTIES"]) {
            let mut props = BTreeMap::new();
            properties(c, &mut props)?;
            if let Some(v) = props.remove("format-version") {
                self.ice(ti).format_version = Some(v.parse().map_err(|_| Fallback)?);
            }
            self.ice(ti).properties.extend(props);
        } else {
            return Err(Fallback);
        }
        if !c.at_end() {
            return Err(Fallback);
        }
        if let Some(more) = notes(&st.leading) {
            let t = &mut self.schema.tables[ti];
            t.notes = Some(match t.notes.take() {
                Some(n) => format!("{n}\n\n{more}"),
                None => more,
            });
        }
        self.last = Some(self.schema.tables[ti].id.clone());
        Ok(())
    }

    fn ice(&mut self, ti: usize) -> &mut IcebergTable {
        self.schema.tables[ti].options.iceberg.get_or_insert_with(IcebergTable::default)
    }

    fn create_view(&mut self, c: &mut Cur<'_>, st: &Statement) -> Step<()> {
        c.kws(&["IF", "NOT", "EXISTS"]);
        let name = c.qualified().ok_or(Fallback)?;
        if name.len() < 2 {
            return Err(Fallback);
        }
        // Its fields, when written out: names with an optional comment (their types come from the query).
        let mut columns = Vec::new();
        if c.is(&Token::LParen) {
            let (from, to) = c.group().ok_or(Fallback)?;
            for (a, b) in commas(c, from, to) {
                let field = ident_of(&c.toks().get(a).ok_or(Fallback)?.token, Case::Keep).ok_or(Fallback)?;
                let mut cur = Cur { i: a + 1, ..Cur::new(c.st, Case::Keep) };
                let comment = if cur.kw("COMMENT") {
                    Some(string_of(&cur.bump().ok_or(Fallback)?.token).ok_or(Fallback)?)
                } else {
                    None
                };
                if cur.i != b {
                    return Err(Fallback);
                }
                columns.push(schema_forge_core::ViewColumn { name: field, data_type: None, comment });
            }
        }
        let comment =
            if c.kw("COMMENT") { Some(string_of(&c.bump().ok_or(Fallback)?.token).ok_or(Fallback)?) } else { None };
        if !c.kw("AS") {
            return Err(Fallback);
        }
        let definition = c.rest().to_string();
        let namespace = self.namespace(&name[..name.len() - 1])?;
        let view_name = name[name.len() - 1].clone();
        let id = self.new_id(Kind::View, &[&view_name]);
        self.schema.views.push(View {
            id: id.clone(),
            namespace,
            name: view_name,
            comment,
            notes: notes(&st.leading),
            tags: Vec::new(),
            area: None,
            columns,
            definition,
            reads: Vec::new(),
            options: ViewOptions {
                iceberg: Some(IcebergView { dialect: Some("spark".to_string()), ..IcebergView::default() }),
                ..ViewOptions::default()
            },
        });
        self.relations.insert(name, Rel::View(self.schema.views.len() - 1));
        self.last = Some(id);
        Ok(())
    }
}

/// One column: `` `name` TYPE [NOT NULL] [COMMENT '…'] ``.
fn column(c: &Cur<'_>, from: usize, to: usize) -> Step<(String, schema_forge_core::DataType, bool, Option<String>)> {
    let name = ident_of(&c.toks()[from].token, Case::Keep).ok_or(Fallback)?;
    let type_end = type_end(c, from + 1, to);
    let data_type = types::read(&c.toks()[from + 1..type_end]).ok_or(Fallback)?;
    let mut cur = Cur { i: type_end, ..Cur::new(c.st, Case::Keep) };
    let mut nullable = true;
    let mut comment = None;
    while cur.i < to {
        if cur.kws(&["NOT", "NULL"]) {
            nullable = false;
        } else if cur.kw("COMMENT") {
            comment = Some(string_of(&cur.bump().ok_or(Fallback)?.token).ok_or(Fallback)?);
        } else {
            return Err(Fallback);
        }
    }
    Ok((name, data_type, nullable, comment))
}

/// Splits tokens `from..to` at commas outside parentheses and angle brackets (`MAP<STRING, BIGINT>`).
fn commas(c: &Cur<'_>, from: usize, to: usize) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut start = from;
    for (n, tok) in c.toks().iter().enumerate().take(to).skip(from) {
        match tok.token {
            Token::LParen | Token::Lt => depth += 1,
            Token::RParen | Token::Gt => depth -= 1,
            Token::ShiftRight => depth -= 2,
            Token::Comma if depth == 0 => {
                out.push((start, n));
                start = n + 1;
            }
            _ => {}
        }
    }
    if start < to {
        out.push((start, to));
    }
    out
}

/// Where a column's type ends: the first `NOT`, `COMMENT` or `DEFAULT` outside parentheses and angle brackets.
fn type_end(c: &Cur<'_>, from: usize, to: usize) -> usize {
    let mut depth = 0i32;
    for (n, tok) in c.toks().iter().enumerate().take(to).skip(from) {
        let t = &tok.token;
        match t {
            Token::LParen | Token::Lt => depth += 1,
            Token::RParen | Token::Gt => depth -= 1,
            Token::ShiftRight => depth -= 2,
            _ if depth == 0 && (is_kw(t, "NOT") || is_kw(t, "COMMENT") || is_kw(t, "DEFAULT")) => return n,
            _ => {}
        }
    }
    to
}

/// One partition (or sort) item: `` `col` ``, `day(`ts`)`, `bucket(16, `id`)`, `truncate(10, `s`)`, as the
/// Iceberg transform and the column it reads.
fn partition_item(c: &Cur<'_>, from: usize, to: usize) -> Step<(String, String)> {
    let toks = c.toks();
    if to == from + 1 {
        return Ok(("identity".to_string(), ident_of(&toks[from].token, Case::Keep).ok_or(Fallback)?));
    }
    let Token::Word(w) = &toks[from].token else { return Err(Fallback) };
    if toks.get(from + 1).map(|t| &t.token) != Some(&Token::LParen) || toks[to - 1].token != Token::RParen {
        return Err(Fallback);
    }
    let args: Vec<&Token> = toks[from + 2..to - 1].iter().map(|t| &t.token).filter(|t| **t != Token::Comma).collect();
    let column = |t: &Token| ident_of(t, Case::Keep).ok_or(Fallback);
    let number = |t: &Token| match t {
        Token::Number(n, _) => Ok(n.clone()),
        _ => Err(Fallback),
    };
    let name = w.value.to_lowercase();
    match (name.as_str(), args.as_slice()) {
        ("year" | "years", [col]) => Ok(("year".to_string(), column(col)?)),
        ("month" | "months", [col]) => Ok(("month".to_string(), column(col)?)),
        ("day" | "days", [col]) => Ok(("day".to_string(), column(col)?)),
        ("hour" | "hours", [col]) => Ok(("hour".to_string(), column(col)?)),
        ("bucket" | "truncate", [a, b]) => {
            let (n, col) =
                if matches!(a, Token::Number(..)) { (number(a)?, column(b)?) } else { (number(b)?, column(a)?) };
            Ok((format!("{name}[{n}]"), col))
        }
        _ => Err(Fallback),
    }
}

/// `( 'key' = 'value', … )`.
fn properties(c: &mut Cur<'_>, into: &mut BTreeMap<String, String>) -> Step<()> {
    let (a, b) = c.group().ok_or(Fallback)?;
    for (x, y) in c.commas(a, b) {
        let toks = &c.toks()[x..y];
        let [key, Tok { token: Token::Eq, .. }, value] = toks else { return Err(Fallback) };
        into.insert(string_of(&key.token).ok_or(Fallback)?, string_of(&value.token).ok_or(Fallback)?);
    }
    Ok(())
}

/// Design notes from the comment lines before a statement: each line without its `-- ` (or `--`).
fn notes(leading: &str) -> Option<String> {
    if leading.trim().is_empty() {
        return None;
    }
    let lines: Vec<&str> = leading
        .lines()
        .map(|l| {
            let l = l.trim_end();
            l.strip_prefix("-- ").or_else(|| l.strip_prefix("--")).unwrap_or(l)
        })
        .collect();
    Some(lines.join("\n"))
}
