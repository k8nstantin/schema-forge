//! `CREATE TABLE` and `CREATE INDEX`: every clause of a table read into what it means, columns named by name. The
//! reader turns the names into ids when it adds the table to the schema.

use schema_forge_engine::sections::{
    Action, Check, ColumnSection, Generated, Identity, LinkSection, Options, Partition,
};
use serde_json::{Value, json};
use sqlparser::tokenizer::Token;

use crate::lex::Cursor;
use crate::types::{self, Family};

/// A table as written.
#[derive(Debug, Default)]
pub struct Table {
    pub db: Option<String>,
    pub name: String,
    pub columns: Vec<Col>,
    pub primary: Option<KeyDef>,
    pub unique: Vec<KeyDef>,
    pub indexes: Vec<IndexDef>,
    pub checks: Vec<Check>,
    pub fks: Vec<Fk>,
    pub options: Options,
    pub comment: Option<String>,
    pub partitioning: Option<PartDef>,
}

#[derive(Debug)]
pub struct Col {
    pub name: String,
    pub data_type: String,
    pub null: bool,
    pub comment: Option<String>,
    pub section: ColumnSection,
}

/// A part of a key or an index: a column (with a prefix length) or an expression, and its order.
#[derive(Debug, Clone, Default)]
pub struct Part {
    pub column: Option<String>,
    pub expression: Option<String>,
    pub length: Option<i64>,
    pub desc: bool,
}

#[derive(Debug, Default)]
pub struct KeyDef {
    pub name: Option<String>,
    pub parts: Vec<Part>,
    pub options: Options,
}

#[derive(Debug, Default)]
pub struct IndexDef {
    pub name: Option<String>,
    pub unique: bool,
    /// `btree`, `hash`, `fulltext` or `spatial`; `None` is the engine's default.
    pub method: Option<String>,
    pub parts: Vec<Part>,
    pub options: Options,
}

/// A foreign key, its parent named as written.
#[derive(Debug)]
pub struct Fk {
    pub name: Option<String>,
    pub columns: Vec<String>,
    pub parent_db: Option<String>,
    pub parent: String,
    pub parent_columns: Vec<String>,
    pub section: LinkSection,
    /// The clause as written, kept on the table when its parent is not in the schema.
    pub text: String,
}

#[derive(Debug, Default)]
pub struct PartDef {
    pub strategy: String,
    pub by: Vec<By>,
    pub partitions: Vec<Partition>,
    pub options: Options,
}

#[derive(Debug)]
pub enum By {
    Column(String),
    Expression(String),
}

/// Reads `CREATE TABLE`, the cursor after `TABLE`.
///
/// # Errors
/// When a clause is not one this reader knows: the statement is then kept as written.
pub fn create_table(c: &mut Cursor<'_>, families: &[Family], version: &str) -> Result<Table, String> {
    c.eat_kws(&["IF", "NOT", "EXISTS"]);
    let (db, name) = c.qualified()?;
    let mut t = with!(Table { db: db, name: name });
    if c.peek_kw("LIKE") || !matches!(c.peek(), Some(Token::LParen)) {
        return Err("a table made from another (LIKE, AS SELECT) is kept as written".to_string());
    }
    c.expect(&Token::LParen)?;
    loop {
        element(c, &mut t, families, version)?;
        if c.eat(&Token::Comma) {
            continue;
        }
        c.expect(&Token::RParen)?;
        break;
    }
    table_options(c, &mut t)?;
    if c.eat_kws(&["PARTITION", "BY"]) {
        t.partitioning = Some(partitioning(c)?);
    }
    if !c.is_done() {
        return Err(format!("after the table's options: {}", c.here()));
    }
    // A primary key's columns never hold null.
    if let Some(pk) = &t.primary {
        for p in &pk.parts {
            if let Some(col) = t.columns.iter_mut().find(|x| Some(&x.name) == p.column.as_ref()) {
                col.null = false;
            }
        }
    }
    Ok(t)
}

/// Reads `CREATE [UNIQUE|FULLTEXT|SPATIAL] INDEX`, the cursor after `INDEX`: the table it is on, and the index.
///
/// # Errors
/// When a clause is not one this reader knows.
pub fn create_index(c: &mut Cursor<'_>, kind: Option<&str>) -> Result<((Option<String>, String), IndexDef), String> {
    let name = c.name()?;
    let mut index = with!(IndexDef { name: Some(name) });
    match kind {
        Some("UNIQUE") => index.unique = true,
        Some(k) => index.method = Some(k.to_ascii_lowercase()),
        None => {}
    }
    if c.eat_kw("USING") {
        index.method = Some(c.name()?.to_ascii_lowercase());
    }
    c.expect_kw("ON")?;
    let table = c.qualified()?;
    index.parts = parts(c)?;
    index_options(c, &mut index.options, &mut index.method)?;
    // What an ALTER would also say (ALGORITHM, LOCK) is how it is built, not what it is.
    while c.eat_kw("ALGORITHM") || c.eat_kw("LOCK") {
        c.value()?;
    }
    if !c.is_done() {
        return Err(format!("after the index: {}", c.here()));
    }
    Ok((table, index))
}

fn element(c: &mut Cursor<'_>, t: &mut Table, families: &[Family], version: &str) -> Result<(), String> {
    let constraint = if c.eat_kw("CONSTRAINT") {
        if c.peek_kw("PRIMARY") || c.peek_kw("UNIQUE") || c.peek_kw("FOREIGN") || c.peek_kw("CHECK") {
            None
        } else {
            Some(c.name()?)
        }
    } else {
        None
    };
    if c.eat_kws(&["PRIMARY", "KEY"]) {
        let mut key = KeyDef::default();
        let mut method = None;
        if c.eat_kw("USING") {
            method = Some(c.name()?);
        }
        key.parts = parts(c)?;
        index_options(c, &mut key.options, &mut method)?;
        if let Some(m) = method {
            key.options.insert("method".into(), json!(m.to_ascii_uppercase()));
        }
        if t.primary.replace(key).is_some() {
            return Err("a second primary key".to_string());
        }
    } else if c.eat_kw("UNIQUE") {
        let _ = c.eat_kw("INDEX") || c.eat_kw("KEY");
        let mut index = with!(IndexDef { unique: true });
        index.name = index_name(c)?.or(constraint);
        if c.eat_kw("USING") {
            index.method = Some(c.name()?.to_ascii_lowercase());
        }
        index.parts = parts(c)?;
        index_options(c, &mut index.options, &mut index.method)?;
        add_unique(t, index);
    } else if c.peek_kw("FULLTEXT") || c.peek_kw("SPATIAL") || c.peek_kw("INDEX") || c.peek_kw("KEY") {
        let mut index = IndexDef::default();
        if c.eat_kw("FULLTEXT") {
            index.method = Some("fulltext".into());
        } else if c.eat_kw("SPATIAL") {
            index.method = Some("spatial".into());
        }
        let _ = c.eat_kw("INDEX") || c.eat_kw("KEY");
        index.name = index_name(c)?;
        if c.eat_kw("USING") {
            index.method = Some(c.name()?.to_ascii_lowercase());
        }
        index.parts = parts(c)?;
        index_options(c, &mut index.options, &mut index.method)?;
        t.indexes.push(index);
    } else if c.peek_kw("FOREIGN") {
        let from = c.mark();
        c.eat_kws(&["FOREIGN", "KEY"]);
        let index_name = index_name(c)?;
        let columns = names(c)?;
        let mut fk = references(c, columns, constraint.or(index_name))?;
        fk.text = c.since(from).to_string();
        t.fks.push(fk);
    } else if c.peek_kw("CHECK") {
        t.checks.push(check(c, constraint)?);
    } else if constraint.is_some() {
        return Err(format!("a constraint that is not a key or a check: {}", c.here()));
    } else {
        column(c, t, families, version)?;
    }
    Ok(())
}

/// A unique key: whole columns are a key of the table; one with an expression is a unique index.
fn add_unique(t: &mut Table, index: IndexDef) {
    if index.parts.iter().all(|p| p.column.is_some()) {
        let mut options = index.options;
        if let Some(m) = index.method {
            options.insert("method".into(), json!(m.to_ascii_uppercase()));
        }
        t.unique.push(KeyDef { name: index.name, parts: index.parts, options });
    } else {
        t.indexes.push(index);
    }
}

/// An index's name, when one is written before its parts.
fn index_name(c: &mut Cursor<'_>) -> Result<Option<String>, String> {
    if matches!(c.peek(), Some(Token::Word(_))) && !c.peek_kw("USING") { Ok(Some(c.name()?)) } else { Ok(None) }
}

/// `(part, …)`: columns with a prefix length, or expressions in parentheses, each ascending or descending.
fn parts(c: &mut Cursor<'_>) -> Result<Vec<Part>, String> {
    c.expect(&Token::LParen)?;
    let mut out = Vec::new();
    loop {
        let mut p = Part::default();
        if matches!(c.peek(), Some(Token::LParen)) {
            p.expression = Some(c.parens()?.to_string());
        } else {
            p.column = Some(c.name()?);
            if c.eat(&Token::LParen) {
                p.length = Some(c.number()?);
                c.expect(&Token::RParen)?;
            }
        }
        if c.eat_kw("DESC") {
            p.desc = true;
        } else {
            c.eat_kw("ASC");
        }
        out.push(p);
        if !c.eat(&Token::Comma) {
            break;
        }
    }
    c.expect(&Token::RParen)?;
    Ok(out)
}

fn index_options(c: &mut Cursor<'_>, options: &mut Options, method: &mut Option<String>) -> Result<(), String> {
    loop {
        if c.eat_kw("KEY_BLOCK_SIZE") {
            c.eat(&Token::Eq);
            options.insert("key_block_size".into(), json!(c.number()?));
        } else if c.eat_kw("USING") {
            *method = Some(c.name()?.to_ascii_lowercase());
        } else if c.eat_kws(&["WITH", "PARSER"]) {
            options.insert("parser".into(), json!(c.name()?));
        } else if c.eat_kw("COMMENT") {
            options.insert("comment".into(), json!(c.value()?));
        } else if c.eat_kw("INVISIBLE") {
            options.insert("invisible".into(), json!(true));
        } else if c.eat_kw("VISIBLE") {
        } else if c.eat_kw("ENGINE_ATTRIBUTE") {
            options.insert("engine_attribute".into(), json!(c.value()?));
        } else {
            return Ok(());
        }
    }
}

/// `(name, …)`.
fn names(c: &mut Cursor<'_>) -> Result<Vec<String>, String> {
    c.expect(&Token::LParen)?;
    let mut out = Vec::new();
    if c.eat(&Token::RParen) {
        return Ok(out);
    }
    loop {
        out.push(c.name()?);
        if !c.eat(&Token::Comma) {
            break;
        }
    }
    c.expect(&Token::RParen)?;
    Ok(out)
}

/// `REFERENCES parent (columns) [MATCH …] [ON DELETE …] [ON UPDATE …]`.
fn references(c: &mut Cursor<'_>, columns: Vec<String>, name: Option<String>) -> Result<Fk, String> {
    c.expect_kw("REFERENCES")?;
    let (parent_db, parent) = c.qualified()?;
    let parent_columns = names(c)?;
    let mut section = LinkSection::default();
    loop {
        if c.eat_kw("MATCH") {
            section.match_kind = Some(c.name()?.to_ascii_lowercase());
        } else if c.eat_kws(&["ON", "DELETE"]) {
            section.on_delete = Some(action(c)?);
        } else if c.eat_kws(&["ON", "UPDATE"]) {
            section.on_update = Some(action(c)?);
        } else {
            break;
        }
    }
    Ok(Fk { name, columns, parent_db, parent, parent_columns, section, text: String::new() })
}

fn action(c: &mut Cursor<'_>) -> Result<Action, String> {
    if c.eat_kw("RESTRICT") {
        Ok(Action::Restrict)
    } else if c.eat_kw("CASCADE") {
        Ok(Action::Cascade)
    } else if c.eat_kws(&["SET", "NULL"]) {
        Ok(Action::SetNull)
    } else if c.eat_kws(&["SET", "DEFAULT"]) {
        Ok(Action::SetDefault)
    } else if c.eat_kws(&["NO", "ACTION"]) {
        Ok(Action::NoAction)
    } else {
        Err(format!("not a foreign key action: {}", c.here()))
    }
}

/// `CHECK (expression) [[NOT] ENFORCED]`.
fn check(c: &mut Cursor<'_>, name: Option<String>) -> Result<Check, String> {
    c.expect_kw("CHECK")?;
    let mut check = with!(Check { name: name, expression: strip_parens(c.parens()?).to_string() });
    if c.eat_kws(&["NOT", "ENFORCED"]) {
        check.options.insert("not_enforced".into(), json!(true));
    } else {
        c.eat_kw("ENFORCED");
    }
    Ok(check)
}

/// An expression without the parentheses MySQL adds around a whole one: `(a > 0)` is `a > 0`.
fn strip_parens(e: &str) -> &str {
    let t = e.trim();
    if t.starts_with('(') && t.ends_with(')') {
        let mut depth = 0;
        for (i, ch) in t.char_indices() {
            match ch {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 && i + 1 < t.len() {
                        return t;
                    }
                }
                _ => {}
            }
        }
        return t[1..t.len() - 1].trim();
    }
    t
}

/// A column: its name, its type, and each clause after it.
fn column(c: &mut Cursor<'_>, t: &mut Table, families: &[Family], version: &str) -> Result<(), String> {
    let name = c.name()?;
    let raw = type_text(c)?;
    let data_type = types::parse(families, raw, version).map_err(|e| format!("`{name}`: {e}"))?.text;
    let mut col = Col { name, data_type, null: true, comment: None, section: ColumnSection::default() };
    let opts = &mut col.section.options;
    loop {
        if c.eat_kws(&["NOT", "NULL"]) {
            col.null = false;
        } else if c.eat_kw("NULL") {
            col.null = true;
        } else if c.eat_kw("DEFAULT") {
            col.section.default = Some(value_text(c)?.to_string());
        } else if c.eat_kw("AUTO_INCREMENT") {
            col.section.identity = Some(Identity::default());
        } else if c.eat_kw("UNIQUE") {
            c.eat_kw("KEY");
            let part = with!(Part { column: Some(col.name.clone()) });
            t.unique.push(KeyDef { name: None, parts: vec![part], options: Options::new() });
        } else if c.eat_kws(&["PRIMARY", "KEY"]) || c.eat_kw("KEY") {
            let part = with!(Part { column: Some(col.name.clone()) });
            if t.primary.replace(with!(KeyDef { parts: vec![part] })).is_some() {
                return Err("a second primary key".to_string());
            }
        } else if c.eat_kw("COMMENT") {
            col.comment = Some(c.value()?);
        } else if c.eat_kw("COLLATE") {
            opts.insert("collation".into(), json!(c.value()?));
        } else if c.eat_kws(&["CHARACTER", "SET"]) || c.eat_kw("CHARSET") {
            opts.insert("charset".into(), json!(c.value()?));
        } else if c.eat_kws(&["GENERATED", "ALWAYS"]) || c.peek_kw("AS") {
            c.expect_kw("AS")?;
            let expression = c.parens()?.to_string();
            let stored = if c.eat_kw("STORED") {
                true
            } else {
                c.eat_kw("VIRTUAL");
                false
            };
            col.section.generated = Some(with!(Generated { expression: expression, stored: stored }));
        } else if c.eat_kw("INVISIBLE") {
            opts.insert("invisible".into(), json!(true));
        } else if c.eat_kw("VISIBLE") {
        } else if c.eat_kws(&["ON", "UPDATE"]) {
            opts.insert("on_update".into(), json!(value_text(c)?));
        } else if c.eat_kw("SRID") {
            opts.insert("srid".into(), json!(c.number()?));
        } else if c.eat_kw("COLUMN_FORMAT") {
            opts.insert("column_format".into(), json!(c.name()?.to_ascii_uppercase()));
        } else if c.eat_kw("STORAGE") {
            opts.insert("storage".into(), json!(c.name()?.to_ascii_uppercase()));
        } else if c.eat_kw("ENGINE_ATTRIBUTE") {
            opts.insert("engine_attribute".into(), json!(c.value()?));
        } else if c.eat_kw("SECONDARY_ENGINE_ATTRIBUTE") {
            opts.insert("secondary_engine_attribute".into(), json!(c.value()?));
        } else if c.peek_kw("REFERENCES") {
            let from = c.mark();
            let mut fk = references(c, vec![col.name.clone()], None)?;
            fk.text = c.since(from).to_string();
            fk.section.options.insert("inline".into(), json!(true));
            t.fks.push(fk);
        } else if c.peek_kw("CHECK") || c.peek_kw("CONSTRAINT") {
            let name = if c.eat_kw("CONSTRAINT") && !c.peek_kw("CHECK") { Some(c.name()?) } else { None };
            t.checks.push(check(c, name)?);
        } else if matches!(c.peek(), Some(Token::Comma | Token::RParen)) {
            break;
        } else {
            return Err(format!("`{}`: not a column clause: {}", col.name, c.here()));
        }
    }
    t.columns.push(col);
    Ok(())
}

/// A type as written: its name (of one or two words), its parameters, and `UNSIGNED`, `SIGNED`, `ZEROFILL`.
pub fn type_text<'a>(c: &mut Cursor<'a>) -> Result<&'a str, String> {
    let from = c.mark();
    let first = c.name()?.to_ascii_lowercase();
    let second: &[&str] = match first.as_str() {
        "double" => &["precision"],
        "character" | "char" => &["varying"],
        "national" => &["char", "character", "varchar"],
        "long" => &["varchar", "varbinary"],
        _ => &[],
    };
    if second.iter().any(|w| c.eat_kw(w)) && first == "national" {
        c.eat_kw("varying");
    }
    if matches!(c.peek(), Some(Token::LParen)) {
        c.parens()?;
    }
    while c.eat_kw("UNSIGNED") || c.eat_kw("SIGNED") || c.eat_kw("ZEROFILL") {}
    Ok(c.since(from))
}

/// A default or an `ON UPDATE` value as written: a literal, a function (`CURRENT_TIMESTAMP(6)`), or an expression in
/// parentheses.
fn value_text<'a>(c: &mut Cursor<'a>) -> Result<&'a str, String> {
    let from = c.mark();
    if matches!(c.peek(), Some(Token::LParen)) {
        c.parens()?;
        return Ok(c.since(from));
    }
    let _ = c.eat(&Token::Minus) || c.eat(&Token::Plus);
    let introducer = matches!(c.peek(), Some(Token::Word(w)) if w.quote_style.is_none() && w.value.starts_with('_'));
    if c.next().is_none() {
        return Err("a default with no value".to_string());
    }
    if introducer && matches!(c.peek(), Some(Token::SingleQuotedString(_))) {
        c.next();
    }
    if matches!(c.peek(), Some(Token::LParen)) {
        c.parens()?;
    }
    Ok(c.since(from))
}

/// The table's options after its columns, in any order, commas between them or not.
fn table_options(c: &mut Cursor<'_>, t: &mut Table) -> Result<(), String> {
    const INTEGERS: &[&str] = &["AUTO_INCREMENT", "AVG_ROW_LENGTH", "KEY_BLOCK_SIZE", "MAX_ROWS", "MIN_ROWS"];
    const TEXTS: &[&str] = &[
        "ENGINE",
        "AUTOEXTEND_SIZE",
        "CHECKSUM",
        "COMPRESSION",
        "CONNECTION",
        "DELAY_KEY_WRITE",
        "ENCRYPTION",
        "ENGINE_ATTRIBUTE",
        "SECONDARY_ENGINE_ATTRIBUTE",
        "SECONDARY_ENGINE",
        "INSERT_METHOD",
        "PACK_KEYS",
        "ROW_FORMAT",
        "STATS_AUTO_RECALC",
        "STATS_PERSISTENT",
        "STATS_SAMPLE_PAGES",
    ];
    loop {
        c.eat(&Token::Comma);
        if c.is_done() || c.peek_kw("PARTITION") {
            return Ok(());
        }
        let default = c.eat_kw("DEFAULT");
        if c.eat_kws(&["CHARACTER", "SET"]) || c.eat_kw("CHARSET") {
            t.options.insert("charset".into(), json!(c.value()?));
        } else if c.eat_kw("COLLATE") {
            t.options.insert("collation".into(), json!(c.value()?));
        } else if default {
            return Err(format!("DEFAULT {} is not a table option", c.here()));
        } else if c.eat_kw("COMMENT") {
            t.comment = Some(c.value()?);
        } else if c.eat_kws(&["DATA", "DIRECTORY"]) {
            t.options.insert("data_directory".into(), json!(c.value()?));
        } else if c.eat_kws(&["INDEX", "DIRECTORY"]) {
            t.options.insert("index_directory".into(), json!(c.value()?));
        } else if c.eat_kw("TABLESPACE") {
            t.options.insert("tablespace".into(), json!(c.value()?));
            if c.peek_kw("STORAGE") {
                return Err("a table's tablespace STORAGE (NDB) is kept as written".to_string());
            }
        } else if c.eat_kw("UNION") {
            c.eat(&Token::Eq);
            t.options.insert("union".into(), json!(names(c)?));
        } else if let Some(k) = INTEGERS.iter().find(|k| c.eat_kw(k)) {
            c.eat(&Token::Eq);
            t.options.insert(k.to_ascii_lowercase(), json!(c.number()?));
        } else if let Some(k) = TEXTS.iter().find(|k| c.eat_kw(k)) {
            t.options.insert(k.to_ascii_lowercase(), json!(c.value()?));
        } else {
            return Err(format!("not a table option: {}", c.here()));
        }
    }
}

/// `PARTITION BY …`, the cursor after `BY`.
fn partitioning(c: &mut Cursor<'_>) -> Result<PartDef, String> {
    let mut p = PartDef::default();
    let (strategy, by, linear, algorithm, columns) = split_by(c)?;
    p.strategy = strategy;
    p.by = by;
    if linear {
        p.options.insert("linear".into(), json!(true));
    }
    if let Some(a) = algorithm {
        p.options.insert("algorithm".into(), json!(a));
    }
    if columns {
        p.options.insert("columns".into(), json!(true));
    }
    if c.eat_kw("PARTITIONS") {
        p.options.insert("count".into(), json!(c.number()?));
    }
    if c.eat_kws(&["SUBPARTITION", "BY"]) {
        let from = c.mark();
        let (strategy, _, linear, algorithm, _) = split_by(c)?;
        let by_text = c.since(from);
        let by = by_text.find('(').map_or("", |i| strip_outer(&by_text[i..]));
        let mut sub = serde_json::Map::new();
        sub.insert("strategy".into(), json!(strategy));
        sub.insert("by".into(), json!(by));
        if linear {
            sub.insert("linear".into(), json!(true));
        }
        if let Some(a) = algorithm {
            sub.insert("algorithm".into(), json!(a));
        }
        if c.eat_kw("SUBPARTITIONS") {
            sub.insert("count".into(), json!(c.number()?));
        }
        p.options.insert("subpartition".into(), Value::Object(sub));
    }
    if c.eat(&Token::LParen) {
        loop {
            p.partitions.push(partition(c)?);
            if !c.eat(&Token::Comma) {
                break;
            }
        }
        c.expect(&Token::RParen)?;
    }
    Ok(p)
}

/// `(text)` without its parentheses.
fn strip_outer(t: &str) -> &str {
    let t = t.trim();
    t.strip_prefix('(').and_then(|x| x.strip_suffix(')')).map_or(t, str::trim)
}

type SplitBy = (String, Vec<By>, bool, Option<i64>, bool);

/// `[LINEAR] HASH (e)`, `[LINEAR] KEY [ALGORITHM = n] (cols)`, `RANGE|LIST (e)`, `RANGE|LIST COLUMNS (cols)`.
fn split_by(c: &mut Cursor<'_>) -> Result<SplitBy, String> {
    let linear = c.eat_kw("LINEAR");
    let strategy = c.name()?.to_ascii_lowercase();
    let mut algorithm = None;
    let mut columns = false;
    let by = match strategy.as_str() {
        "key" => {
            if c.eat_kw("ALGORITHM") {
                c.eat(&Token::Eq);
                algorithm = Some(c.number()?);
            }
            names(c)?.into_iter().map(By::Column).collect()
        }
        "range" | "list" if c.eat_kw("COLUMNS") => {
            columns = true;
            names(c)?.into_iter().map(By::Column).collect()
        }
        "hash" | "range" | "list" => vec![expression_or_column(c.parens()?)],
        other => return Err(format!("not a way to partition: {other}")),
    };
    Ok((strategy, by, linear, algorithm, columns))
}

/// A partitioning expression that is one column is that column.
fn expression_or_column(e: &str) -> By {
    let t = e.trim();
    let bare = |s: &str| !s.is_empty() && s.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '$');
    if let Some(inner) = t.strip_prefix('`').and_then(|x| x.strip_suffix('`'))
        && !inner.contains('`')
    {
        return By::Column(inner.to_string());
    }
    if bare(t) && !t.chars().all(|ch| ch.is_ascii_digit()) {
        return By::Column(t.to_string());
    }
    By::Expression(t.to_string())
}

/// `PARTITION name [VALUES …] [options] [(SUBPARTITION …, …)]`.
fn partition(c: &mut Cursor<'_>) -> Result<Partition, String> {
    c.expect_kw("PARTITION")?;
    let name = c.name()?;
    let mut bounds = String::new();
    if c.peek_kw("VALUES") {
        let from = c.mark();
        c.next();
        if c.eat_kws(&["LESS", "THAN"]) {
            if !c.eat_kw("MAXVALUE") {
                c.parens()?;
            }
        } else {
            c.expect_kw("IN")?;
            c.parens()?;
        }
        bounds = c.since(from).to_string();
    }
    let mut part = with!(Partition { name: name, bounds: bounds });
    partition_options(c, &mut part.options)?;
    if c.eat(&Token::LParen) {
        let mut subs = Vec::new();
        loop {
            c.expect_kw("SUBPARTITION")?;
            let mut sub = Options::new();
            sub.insert("name".into(), json!(c.name()?));
            partition_options(c, &mut sub)?;
            subs.push(Value::Object(sub));
            if !c.eat(&Token::Comma) {
                break;
            }
        }
        c.expect(&Token::RParen)?;
        part.options.insert("subpartitions".into(), Value::Array(subs));
    }
    Ok(part)
}

fn partition_options(c: &mut Cursor<'_>, o: &mut Options) -> Result<(), String> {
    loop {
        if c.eat_kws(&["STORAGE", "ENGINE"]) || c.eat_kw("ENGINE") {
            o.insert("engine".into(), json!(c.value()?));
        } else if c.eat_kw("COMMENT") {
            o.insert("comment".into(), json!(c.value()?));
        } else if c.eat_kws(&["DATA", "DIRECTORY"]) {
            o.insert("data_directory".into(), json!(c.value()?));
        } else if c.eat_kws(&["INDEX", "DIRECTORY"]) {
            o.insert("index_directory".into(), json!(c.value()?));
        } else if c.eat_kw("MAX_ROWS") {
            c.eat(&Token::Eq);
            o.insert("max_rows".into(), json!(c.number()?));
        } else if c.eat_kw("MIN_ROWS") {
            c.eat(&Token::Eq);
            o.insert("min_rows".into(), json!(c.number()?));
        } else if c.eat_kw("TABLESPACE") {
            o.insert("tablespace".into(), json!(c.value()?));
        } else {
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::BUILT_IN;

    fn table(sql: &str) -> Result<Table, String> {
        let mut c = Cursor::new(sql).expect("tokens");
        assert!(c.eat_kws(&["CREATE", "TABLE"]));
        create_table(&mut c, BUILT_IN, "8.4")
    }

    #[test]
    fn every_column_clause_is_read() {
        let t = table(
            "CREATE TABLE t (`id` bigint unsigned NOT NULL AUTO_INCREMENT, `c` char(8) CHARACTER SET ascii \
             COLLATE ascii_bin DEFAULT NULL COMMENT 'it''s', `g` varchar(9) GENERATED ALWAYS AS (upper(`c`)) STORED, \
             `u` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, `d` binary(16) NOT NULL \
             DEFAULT (uuid_to_bin(uuid())), `s` varchar(2) DEFAULT NULL INVISIBLE, `p` point NOT NULL SRID 4326, \
             `n` int DEFAULT -1, `b` bit(2) DEFAULT b'01', PRIMARY KEY (`id`))",
        )
        .expect("a table");
        let col = |n: &str| t.columns.iter().find(|c| c.name == n).expect("the column");
        assert!(!col("id").null && col("id").section.identity.is_some());
        assert_eq!(col("c").section.options["charset"], "ascii");
        assert_eq!(col("c").comment.as_deref(), Some("it's"));
        assert_eq!(col("c").section.default.as_deref(), Some("NULL"));
        assert_eq!(
            col("g").section.generated.as_ref().map(|g| (g.expression.as_str(), g.stored)),
            Some(("upper(`c`)", true))
        );
        assert_eq!(col("u").section.options["on_update"], "CURRENT_TIMESTAMP");
        assert_eq!(col("d").section.default.as_deref(), Some("(uuid_to_bin(uuid()))"));
        assert_eq!(col("s").section.options["invisible"], true);
        assert_eq!(col("p").section.options["srid"], 4326);
        assert_eq!(col("n").section.default.as_deref(), Some("-1"));
        assert_eq!(col("b").section.default.as_deref(), Some("b'01'"));
    }

    #[test]
    fn keys_indexes_checks_and_foreign_keys_are_read() {
        let t = table(
            "CREATE TABLE o (`a` int NOT NULL, `b` varchar(20), `c` text, PRIMARY KEY (`a`), UNIQUE KEY `u` (`b`(4)), \
             KEY `k` (`a` DESC, `b`) COMMENT 'x' /*!80000 INVISIBLE */, KEY `f` ((lower(`b`))), FULLTEXT KEY `t` (`c`) \
             WITH PARSER `ngram`, CONSTRAINT `fk` FOREIGN KEY (`a`) REFERENCES `p` (`id`) ON DELETE CASCADE, \
             CONSTRAINT `ck` CHECK ((`a` > 0)) NOT ENFORCED) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4 \
             COMMENT='orders'",
        )
        .expect("a table");
        assert_eq!(t.primary.as_ref().map(|k| k.parts.len()), Some(1));
        assert_eq!(t.unique[0].parts[0].length, Some(4));
        assert!(t.indexes[0].parts[0].desc && t.indexes[0].options["invisible"] == true);
        assert_eq!(t.indexes[1].parts[0].expression.as_deref(), Some("lower(`b`)"));
        assert_eq!(
            (t.indexes[2].method.as_deref(), &t.indexes[2].options["parser"]),
            (Some("fulltext"), &json!("ngram"))
        );
        assert_eq!((t.fks[0].name.as_deref(), t.fks[0].section.on_delete), (Some("fk"), Some(Action::Cascade)));
        assert_eq!(t.checks[0].expression, "`a` > 0");
        assert_eq!(t.checks[0].options["not_enforced"], true);
        assert_eq!((&t.options["engine"], &t.options["auto_increment"]), (&json!("InnoDB"), &json!(5)));
        assert_eq!(t.comment.as_deref(), Some("orders"));
    }

    #[test]
    fn partitioning_is_read_whole() {
        let t = table(
            "CREATE TABLE m (`id` int NOT NULL, `taken` date NOT NULL) ENGINE=InnoDB PARTITION BY RANGE \
             (to_days(`taken`)) SUBPARTITION BY HASH (`id`) SUBPARTITIONS 2 (PARTITION a VALUES LESS THAN (739982) \
             COMMENT = 'old' ENGINE = InnoDB, PARTITION b VALUES LESS THAN MAXVALUE ENGINE = InnoDB)",
        )
        .expect("a table");
        let p = t.partitioning.expect("partitioned");
        assert_eq!(p.strategy, "range");
        assert!(matches!(&p.by[0], By::Expression(e) if e == "to_days(`taken`)"));
        assert_eq!(p.options["subpartition"], json!({ "strategy": "hash", "by": "`id`", "count": 2 }));
        assert_eq!(p.partitions[0].bounds, "VALUES LESS THAN (739982)");
        assert_eq!(p.partitions[0].options["comment"], "old");
        assert_eq!(p.partitions[1].bounds, "VALUES LESS THAN MAXVALUE");
        let k = table("CREATE TABLE s (`t` varchar(4) NOT NULL) PARTITION BY LINEAR KEY (t) PARTITIONS 4")
            .expect("a table")
            .partitioning
            .expect("partitioned");
        assert!(matches!(&k.by[0], By::Column(c) if c == "t"));
        assert_eq!((&k.options["linear"], &k.options["count"]), (&json!(true), &json!(4)));
    }

    #[test]
    fn what_is_not_known_is_an_error_never_dropped() {
        assert!(table("CREATE TABLE t (a int BOGUS)").is_err());
        assert!(table("CREATE TABLE t LIKE u").is_err());
        assert!(table("CREATE TABLE t (a int) FROBNICATE=1").is_err());
    }
}
