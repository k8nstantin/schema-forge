//! Views and stored programs: `CREATE VIEW`, `PROCEDURE`, `FUNCTION`, `TRIGGER`, `EVENT`, `LIBRARY`, and loadable
//! functions. Each body is kept exactly as written; every clause around it is read into what it means.

use schema_forge_engine::sections::{Change, Event, Mode, Options, Parameter, Routine, Timing};
use serde_json::json;
use sqlparser::tokenizer::Token;

use crate::lex::Cursor;

/// What comes between `CREATE` and the kind of object: `OR REPLACE`, `ALGORITHM`, `DEFINER`, `SQL SECURITY`,
/// `AGGREGATE`.
#[derive(Debug, Default)]
pub struct Head {
    pub options: Options,
    pub aggregate: bool,
}

/// Reads the clauses before the kind; the cursor after `CREATE`.
///
/// # Errors
/// When a clause is not complete.
pub fn head(c: &mut Cursor<'_>) -> Result<Head, String> {
    let mut h = Head::default();
    loop {
        if c.eat_kws(&["OR", "REPLACE"]) {
        } else if c.eat_kw("ALGORITHM") {
            h.options.insert("algorithm".into(), json!(c.value()?.to_ascii_uppercase()));
        } else if c.eat_kw("DEFINER") {
            c.expect(&Token::Eq)?;
            let from = c.mark();
            c.skip_to_kw(&["SQL", "VIEW", "PROCEDURE", "FUNCTION", "TRIGGER", "EVENT", "LIBRARY", "AGGREGATE"]);
            h.options.insert("definer".into(), json!(c.since(from)));
        } else if c.eat_kws(&["SQL", "SECURITY"]) {
            h.options.insert("security".into(), json!(c.name()?.to_ascii_uppercase()));
        } else if c.eat_kw("AGGREGATE") {
            h.aggregate = true;
        } else {
            return Ok(h);
        }
    }
}

/// A view as written.
#[derive(Debug)]
pub struct View {
    pub db: Option<String>,
    pub name: String,
    pub query: String,
    pub options: Options,
}

/// Reads a view, the cursor after `VIEW`.
///
/// # Errors
/// When it has no query.
pub fn view(c: &mut Cursor<'_>, head: Head) -> Result<View, String> {
    let (db, name) = c.qualified()?;
    let mut options = head.options;
    if matches!(c.peek(), Some(Token::LParen)) {
        c.next();
        let mut cols = Vec::new();
        loop {
            cols.push(json!(c.name()?));
            if !c.eat(&Token::Comma) {
                break;
            }
        }
        c.expect(&Token::RParen)?;
        options.insert("column_list".into(), json!(cols));
    }
    c.expect_kw("AS")?;
    let from = c.mark();
    let n = c.len();
    // `WITH [CASCADED | LOCAL] CHECK OPTION` at the very end; a `WITH` anywhere else is the query's own.
    let mut to = n;
    if n >= 3 && c.kw_at(n - 1, "OPTION") && c.kw_at(n - 2, "CHECK") {
        let (with, kind) = if c.kw_at(n - 3, "WITH") {
            (n - 3, "CASCADED".to_string())
        } else if n >= 4 && c.kw_at(n - 4, "WITH") && (c.kw_at(n - 3, "CASCADED") || c.kw_at(n - 3, "LOCAL")) {
            let k = if c.kw_at(n - 3, "LOCAL") { "LOCAL" } else { "CASCADED" };
            (n - 4, k.to_string())
        } else {
            (n, String::new())
        };
        if with < n {
            to = with;
            options.insert("check_option".into(), json!(kind));
        }
    }
    let query = c.slice(from, to).to_string();
    c.reset(n);
    if query.is_empty() {
        return Err("a view without a query".to_string());
    }
    Ok(View { db, name, query, options })
}

/// A procedure, a function or a library as written.
#[derive(Debug)]
pub struct Program {
    pub db: Option<String>,
    pub name: String,
    pub comment: Option<String>,
    pub routine: Routine,
    pub options: Options,
}

/// Reads a procedure or a stored function, the cursor after `PROCEDURE` or `FUNCTION`.
///
/// # Errors
/// When a clause is not complete, or it has no body.
pub fn routine(c: &mut Cursor<'_>, head: Head, function: bool) -> Result<Program, String> {
    c.eat_kws(&["IF", "NOT", "EXISTS"]);
    let (db, name) = c.qualified()?;
    let mut r = with!(Routine { parameters: parameters(c, !function)? });
    if function {
        c.expect_kw("RETURNS")?;
        let from = c.mark();
        crate::read::table::type_text(c)?;
        if c.eat_kws(&["CHARACTER", "SET"]) || c.eat_kw("CHARSET") {
            c.name()?;
        }
        if c.eat_kw("COLLATE") {
            c.name()?;
        }
        r.returns = Some(c.since(from).to_string());
    }
    let mut p = Program { db, name, comment: None, routine: r, options: head.options };
    characteristics(c, &mut p)?;
    p.routine.body = c.rest().to_string();
    if p.routine.body.is_empty() {
        return Err("a routine without a body".to_string());
    }
    Ok(p)
}

/// Reads a library, the cursor after `LIBRARY`.
///
/// # Errors
/// When a clause is not complete, or it has no body.
pub fn library(c: &mut Cursor<'_>, head: Head) -> Result<Program, String> {
    c.eat_kws(&["IF", "NOT", "EXISTS"]);
    let (db, name) = c.qualified()?;
    let mut p = Program { db, name, comment: None, routine: Routine::default(), options: head.options };
    characteristics(c, &mut p)?;
    p.routine.body = c.rest().to_string();
    if !p.routine.body.to_ascii_uppercase().starts_with("AS") {
        return Err("a library without its source (AS …)".to_string());
    }
    Ok(p)
}

/// `(parameter, …)`: each `[IN | OUT | INOUT] name type`, the type as written.
fn parameters(c: &mut Cursor<'_>, modes: bool) -> Result<Vec<Parameter>, String> {
    c.expect(&Token::LParen)?;
    let mut out = Vec::new();
    if c.eat(&Token::RParen) {
        return Ok(out);
    }
    loop {
        let mode = if !modes {
            None
        } else if c.eat_kw("INOUT") {
            Some(Mode::InOut)
        } else if c.eat_kw("OUT") {
            Some(Mode::Out)
        } else if c.eat_kw("IN") {
            Some(Mode::In)
        } else {
            None
        };
        let name = c.name()?;
        let from = c.mark();
        let mut depth = 0;
        while let Some(t) = c.peek() {
            match t {
                Token::LParen => depth += 1,
                Token::RParen if depth == 0 => break,
                Token::RParen => depth -= 1,
                Token::Comma if depth == 0 => break,
                _ => {}
            }
            c.next();
        }
        let data_type = c.since(from).to_string();
        out.push(with!(Parameter { name: name, data_type: data_type, mode: mode }));
        if !c.eat(&Token::Comma) {
            break;
        }
    }
    c.expect(&Token::RParen)?;
    Ok(out)
}

/// The characteristics before a body, in any order.
fn characteristics(c: &mut Cursor<'_>, p: &mut Program) -> Result<(), String> {
    let r = &mut p.routine;
    loop {
        if c.eat_kw("COMMENT") {
            p.comment = Some(c.string()?);
        } else if c.eat_kw("LANGUAGE") {
            r.language = Some(c.name()?.to_ascii_lowercase());
        } else if c.eat_kws(&["NOT", "DETERMINISTIC"]) {
            r.deterministic = Some(false);
        } else if c.eat_kw("DETERMINISTIC") {
            r.deterministic = Some(true);
        } else if c.eat_kws(&["CONTAINS", "SQL"]) {
            r.options.insert("data_access".into(), json!("CONTAINS SQL"));
        } else if c.eat_kws(&["NO", "SQL"]) {
            r.options.insert("data_access".into(), json!("NO SQL"));
        } else if c.eat_kws(&["READS", "SQL", "DATA"]) {
            r.options.insert("data_access".into(), json!("READS SQL DATA"));
        } else if c.eat_kws(&["MODIFIES", "SQL", "DATA"]) {
            r.options.insert("data_access".into(), json!("MODIFIES SQL DATA"));
        } else if c.eat_kws(&["SQL", "SECURITY"]) {
            r.security = Some(c.name()?.to_ascii_lowercase());
        } else if c.peek_kw("USING") && matches!(c.peek_at(1), Some(Token::LParen)) {
            c.next();
            let list = c.parens()?;
            let items: Vec<&str> = list.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
            r.options.insert("imports".into(), json!(items));
        } else {
            return Ok(());
        }
    }
}

/// A trigger as written, its table named.
#[derive(Debug)]
pub struct TriggerDef {
    pub db: Option<String>,
    pub name: String,
    pub timing: Timing,
    pub change: Change,
    pub table: (Option<String>, String),
    pub body: String,
    pub options: Options,
}

/// Reads a trigger, the cursor after `TRIGGER`.
///
/// # Errors
/// When a clause is not complete, or it has no body.
pub fn trigger(c: &mut Cursor<'_>, head: Head) -> Result<TriggerDef, String> {
    c.eat_kws(&["IF", "NOT", "EXISTS"]);
    let (db, name) = c.qualified()?;
    let timing = if c.eat_kw("BEFORE") {
        Timing::Before
    } else {
        c.expect_kw("AFTER")?;
        Timing::After
    };
    let change = if c.eat_kw("INSERT") {
        Change::Insert
    } else if c.eat_kw("UPDATE") {
        Change::Update
    } else {
        c.expect_kw("DELETE")?;
        Change::Delete
    };
    c.expect_kw("ON")?;
    let table = c.qualified()?;
    c.expect_kw("FOR")?;
    c.expect_kw("EACH")?;
    c.expect_kw("ROW")?;
    let mut options = head.options;
    if c.eat_kw("FOLLOWS") {
        options.insert("follows".into(), json!(c.name()?));
    } else if c.eat_kw("PRECEDES") {
        options.insert("precedes".into(), json!(c.name()?));
    }
    let body = c.rest().to_string();
    if body.is_empty() {
        return Err("a trigger without a body".to_string());
    }
    Ok(TriggerDef { db, name, timing, change, table, body, options })
}

/// An event as written.
#[derive(Debug)]
pub struct EventDef {
    pub db: Option<String>,
    pub name: String,
    pub comment: Option<String>,
    pub event: Event,
    pub options: Options,
}

/// Reads an event, the cursor after `EVENT`.
///
/// # Errors
/// When a clause is not complete, or it has no schedule or body.
pub fn event(c: &mut Cursor<'_>, head: Head) -> Result<EventDef, String> {
    c.eat_kws(&["IF", "NOT", "EXISTS"]);
    let (db, name) = c.qualified()?;
    c.expect_kw("ON")?;
    c.expect_kw("SCHEDULE")?;
    let from = c.mark();
    c.skip_to_kw(&["ON", "ENABLE", "DISABLE", "COMMENT", "DO"]);
    let mut e = with!(Event { schedule: c.since(from).to_string() });
    let mut options = head.options;
    let mut comment = None;
    loop {
        if c.eat_kws(&["ON", "COMPLETION", "NOT", "PRESERVE"]) {
            e.preserve = false;
        } else if c.eat_kws(&["ON", "COMPLETION", "PRESERVE"]) {
            e.preserve = true;
        } else if c.eat_kw("ENABLE") {
            e.enabled = true;
        } else if c.eat_kw("DISABLE") {
            e.enabled = false;
            if c.eat_kw("ON") {
                if !(c.eat_kw("REPLICA") || c.eat_kw("SLAVE")) {
                    return Err(format!("DISABLE ON {}", c.here()));
                }
                options.insert("disabled_on_replica".into(), json!(true));
            }
        } else if c.eat_kw("COMMENT") {
            comment = Some(c.string()?);
        } else {
            break;
        }
    }
    c.expect_kw("DO")?;
    e.body = c.rest().to_string();
    if e.schedule.is_empty() || e.body.is_empty() {
        return Err("an event without a schedule or a body".to_string());
    }
    Ok(EventDef { db, name, comment, event: e, options })
}

/// A loadable function: `name RETURNS {STRING|INTEGER|REAL|DECIMAL} SONAME 'file'`, the cursor after its name.
///
/// # Errors
/// When a clause is not complete.
pub fn loadable(c: &mut Cursor<'_>, aggregate: bool) -> Result<Options, String> {
    let mut options = Options::new();
    c.expect_kw("RETURNS")?;
    let returns = c.name()?.to_ascii_uppercase();
    if !["STRING", "INTEGER", "REAL", "DECIMAL"].contains(&returns.as_str()) {
        return Err(format!("a loadable function returns {returns}"));
    }
    options.insert("returns".into(), json!(returns));
    c.expect_kw("SONAME")?;
    options.insert("soname".into(), json!(c.string()?));
    if aggregate {
        options.insert("aggregate".into(), json!(true));
    }
    if !c.is_done() {
        return Err(format!("after the loadable function: {}", c.here()));
    }
    Ok(options)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at<'a>(sql: &'a str, kind: &str) -> (Cursor<'a>, Head) {
        let mut c = Cursor::new(sql).expect("tokens");
        c.expect_kw("CREATE").expect("create");
        let h = head(&mut c).expect("head");
        c.expect_kw(kind).expect("the kind");
        (c, h)
    }

    #[test]
    fn a_view_keeps_its_query_and_reads_its_clauses() {
        let (mut c, h) = at(
            "CREATE ALGORITHM=MERGE DEFINER=`root`@`localhost` SQL SECURITY INVOKER VIEW `v` (`a`,`b`) AS with x as \
             (select 1) select * from x WITH CASCADED CHECK OPTION",
            "VIEW",
        );
        let v = view(&mut c, h).expect("a view");
        assert_eq!(v.query, "with x as (select 1) select * from x");
        assert_eq!(v.options["definer"], "`root`@`localhost`");
        assert_eq!(v.options["security"], "INVOKER");
        assert_eq!(v.options["check_option"], "CASCADED");
        assert_eq!(v.options["column_list"], json!(["a", "b"]));
    }

    #[test]
    fn a_routine_keeps_its_body_and_reads_its_characteristics() {
        let (mut c, h) = at(
            "CREATE DEFINER=`root`@`%` PROCEDURE `p`(IN a bigint unsigned, OUT b enum('x,y','z')) MODIFIES SQL DATA \
             SQL SECURITY INVOKER COMMENT 'Closes' BEGIN\n  SELECT 1;\nEND",
            "PROCEDURE",
        );
        let p = routine(&mut c, h, false).expect("a procedure");
        assert_eq!(p.routine.parameters[1].data_type, "enum('x,y','z')");
        assert_eq!(p.routine.parameters[0].mode, Some(Mode::In));
        assert_eq!(p.routine.body, "BEGIN\n  SELECT 1;\nEND");
        assert_eq!((p.routine.security.as_deref(), p.comment.as_deref()), (Some("invoker"), Some("Closes")));
        let (mut c, h) = at(
            "CREATE FUNCTION f(x decimal(12,2)) RETURNS varchar(9) CHARSET utf8mb4 DETERMINISTIC RETURN x",
            "FUNCTION",
        );
        let f = routine(&mut c, h, true).expect("a function");
        assert_eq!(f.routine.returns.as_deref(), Some("varchar(9) CHARSET utf8mb4"));
        assert_eq!((f.routine.deterministic, f.routine.body.as_str()), (Some(true), "RETURN x"));
    }

    #[test]
    fn triggers_and_events_read_whole() {
        let (mut c, h) =
            at("CREATE TRIGGER `t` BEFORE INSERT ON `shop`.`orders` FOR EACH ROW FOLLOWS `u` SET NEW.a = 1", "TRIGGER");
        let t = trigger(&mut c, h).expect("a trigger");
        assert_eq!(
            (t.table.0.as_deref(), t.table.1.as_str(), t.body.as_str()),
            (Some("shop"), "orders", "SET NEW.a = 1")
        );
        assert_eq!(t.options["follows"], "u");
        let (mut c, h) = at(
            "CREATE EVENT `e` ON SCHEDULE EVERY 1 DAY STARTS '2027-01-01 03:00:00' ON COMPLETION PRESERVE DISABLE ON \
             REPLICA COMMENT 'Keeps' DO DELETE FROM x",
            "EVENT",
        );
        let e = event(&mut c, h).expect("an event");
        assert_eq!(e.event.schedule, "EVERY 1 DAY STARTS '2027-01-01 03:00:00'");
        assert!(e.event.preserve && !e.event.enabled);
        assert_eq!(e.options["disabled_on_replica"], true);
        assert_eq!((e.comment.as_deref(), e.event.body.as_str()), (Some("Keeps"), "DELETE FROM x"));
    }

    #[test]
    fn libraries_and_loadable_functions_read() {
        let (mut c, h) =
            at("CREATE LIBRARY `lib` LANGUAGE JAVASCRIPT AS $$ export function f() { return 'it''s'; } $$", "LIBRARY");
        let l = library(&mut c, h).expect("a library");
        assert_eq!(l.routine.language.as_deref(), Some("javascript"));
        assert!(l.routine.body.starts_with("AS $$ export"));
        let (mut c, h) = at("CREATE AGGREGATE FUNCTION avg2 RETURNS REAL SONAME 'udf.so'", "FUNCTION");
        c.name().expect("its name");
        let o = loadable(&mut c, h.aggregate).expect("a loadable function");
        assert_eq!((&o["returns"], &o["soname"], &o["aggregate"]), (&json!("REAL"), &json!("udf.so"), &json!(true)));
    }
}
