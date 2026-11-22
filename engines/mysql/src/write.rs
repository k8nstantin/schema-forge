//! Writing a schema as MySQL's SQL, in one canonical form: each object as `SHOW CREATE …` writes it, without the
//! versioned comments, every name quoted; stored programs inside `DELIMITER` with the settings they were made under;
//! what the reader kept, written back in its place. What this writes, this engine reads back as the same schema.

use std::collections::HashSet;
use std::fmt::Write as _;

use schema_forge_engine::sections::{
    self, Action, Direction, Index, Kept, Key, LinkSection, NamespaceSection, ObjectSection, Options, SchemaSection,
};
use schema_forge_model::{Id, Object, Schema};
use serde_json::Value;

use crate::kinds::{
    EVENT, FUNCTION, LIBRARY, LOADABLE_FUNCTION, PROCEDURE, SPATIAL_REFERENCE_SYSTEM, TABLE, TABLESPACE, TRIGGER, VIEW,
};
use crate::read::{HEADER, HEADER_TAIL};

/// The whole schema.
///
/// # Errors
/// When a part cannot be written in MySQL's SQL without losing something.
pub fn schema(s: &Schema) -> Result<String, String> {
    sections::layout_of(&s.engine_section)?;
    let section: SchemaSection = sections::read(&s.engine_section)?;
    let mut out = format!("{HEADER} {} {HEADER_TAIL}\nSET FOREIGN_KEY_CHECKS = 0;\n", s.engine.version);
    let kept_after = |out: &mut String, after: Option<&Id>| {
        for k in section.kept.iter().filter(|k| k.after.as_ref() == after) {
            out.push('\n');
            out.push_str(&kept(k));
        }
    };
    kept_after(&mut out, None);
    for n in &s.namespaces {
        let ns: NamespaceSection = sections::read(&n.engine)?;
        let _ = write!(
            out,
            "\nCREATE DATABASE {}{};\nUSE {};\n",
            quote(&n.name),
            database_options(&ns.options),
            quote(&n.name)
        );
        kept_after(&mut out, Some(&n.id));
        // Each object in its order, except a view, which waits for what it reads in its database.
        let mut pending: HashSet<&Id> = s.objects.iter().filter(|o| o.namespace == n.id).map(|o| &o.id).collect();
        let mut waiting: Vec<&Object> = Vec::new();
        for o in s.objects.iter().filter(|o| o.namespace == n.id) {
            waiting.push(o);
            while let Some(at) =
                waiting.iter().position(|w| w.kind != VIEW || w.reads.iter().all(|r| !pending.contains(r)))
            {
                let w = waiting.remove(at);
                out.push('\n');
                out.push_str(&wrapped(s, w)?);
                pending.remove(&w.id);
                kept_after(&mut out, Some(&w.id));
            }
        }
        for w in waiting {
            out.push('\n');
            out.push_str(&wrapped(s, w)?);
            kept_after(&mut out, Some(&w.id));
        }
    }
    out.push_str("\nSET FOREIGN_KEY_CHECKS = 1;\n");
    Ok(out)
}

/// One object's `CREATE` statement, ended by `;`.
///
/// # Errors
/// As [`schema`].
pub fn definition(s: &Schema, id: &Id) -> Result<Option<String>, String> {
    let Some(o) = s.object(id) else { return Ok(None) };
    let (text, _) = create(s, o)?;
    Ok(Some(format!("{text};")))
}

/// An object as the schema writes it: a stored program inside `DELIMITER`, and anything made under settings between
/// setting them and restoring them.
fn wrapped(s: &Schema, o: &Object) -> Result<String, String> {
    let (text, program) = create(s, o)?;
    let section: ObjectSection = sections::read(&o.engine)?;
    let settings = settings(&section.options);
    let mut out = String::new();
    if !settings.is_empty() {
        let save: Vec<String> = settings.iter().map(|(k, _)| format!("@saved_{k} = @@{k}")).collect();
        let set: Vec<String> = settings.iter().map(|(k, v)| format!("{k} = {v}")).collect();
        let _ = writeln!(out, "SET {};\nSET {};", save.join(", "), set.join(", "));
    }
    if program {
        let _ = writeln!(out, "DELIMITER ;;\n{text} ;;\nDELIMITER ;");
    } else {
        let _ = writeln!(out, "{text};");
    }
    if !settings.is_empty() {
        let restore: Vec<String> = settings.iter().map(|(k, _)| format!("{k} = @saved_{k}")).collect();
        let _ = writeln!(out, "SET {};", restore.join(", "));
    }
    Ok(out)
}

/// The settings an object was made under, as `SET` writes them; `character_set_results` follows the client's.
fn settings(options: &Options) -> Vec<(&'static str, String)> {
    let mut out = Vec::new();
    let text = |k: &str| options.get(k).and_then(Value::as_str);
    if let Some(v) = text("character_set_client") {
        out.push(("character_set_client", v.to_string()));
        out.push(("character_set_results", v.to_string()));
    }
    if let Some(v) = text("collation_connection") {
        out.push(("collation_connection", v.to_string()));
    }
    if let Some(v) = text("sql_mode") {
        out.push(("sql_mode", string(v)));
    }
    if let Some(v) = text("time_zone") {
        out.push(("time_zone", string(v)));
    }
    out
}

/// The `CREATE` statement without its delimiter, and whether it is a stored program (written inside `DELIMITER`).
fn create(s: &Schema, o: &Object) -> Result<(String, bool), String> {
    let section: ObjectSection = sections::read(&o.engine)?;
    let opts = &section.options;
    let definer = opts.get("definer").and_then(Value::as_str).map(|d| format!(" DEFINER={d}")).unwrap_or_default();
    let name = quote(&o.name);
    let text = match o.kind.as_str() {
        TABLE => return table(s, o, &section).map(|t| (t, false)),
        VIEW => {
            let mut t = "CREATE".to_string();
            if let Some(a) = text_opt(opts, "algorithm") {
                let _ = write!(t, " ALGORITHM={a}");
            }
            t.push_str(&definer);
            if let Some(sec) = text_opt(opts, "security") {
                let _ = write!(t, " SQL SECURITY {sec}");
            }
            let _ = write!(t, " VIEW {name}");
            if let Some(Value::Array(cols)) = opts.get("column_list") {
                let cols: Vec<String> = cols.iter().filter_map(Value::as_str).map(quote).collect();
                let _ = write!(t, " ({})", cols.join(","));
            }
            let _ = write!(t, " AS {}", section.query.as_deref().ok_or("a view without a query")?);
            if let Some(k) = text_opt(opts, "check_option") {
                let _ = write!(t, " WITH {k} CHECK OPTION");
            }
            return Ok((t, false));
        }
        PROCEDURE | FUNCTION | LIBRARY => {
            let r = section.routine.as_ref().ok_or("a routine without its routine")?;
            let kind = match o.kind.as_str() {
                PROCEDURE => "PROCEDURE",
                FUNCTION => "FUNCTION",
                _ => "LIBRARY",
            };
            let mut t = format!("CREATE{definer} {kind} {name}");
            if o.kind != LIBRARY {
                let params: Vec<String> = r
                    .parameters
                    .iter()
                    .map(|p| {
                        let mode = match p.mode {
                            Some(sections::Mode::In) => "IN ",
                            Some(sections::Mode::Out) => "OUT ",
                            Some(sections::Mode::InOut) => "INOUT ",
                            _ => "",
                        };
                        format!("{mode}{} {}", quote(&p.name), p.data_type)
                    })
                    .collect();
                let _ = write!(t, "({})", params.join(", "));
            }
            if let Some(ret) = &r.returns {
                let _ = write!(t, " RETURNS {ret}");
            }
            let mut lines = Vec::new();
            if let Some(l) = &r.language {
                lines.push(format!("LANGUAGE {}", l.to_ascii_uppercase()));
            }
            if let Some(d) = text_opt(&r.options, "data_access") {
                lines.push(d.to_string());
            }
            match r.deterministic {
                Some(true) => lines.push("DETERMINISTIC".to_string()),
                Some(false) => lines.push("NOT DETERMINISTIC".to_string()),
                None => {}
            }
            if let Some(sec) = &r.security {
                lines.push(format!("SQL SECURITY {}", sec.to_ascii_uppercase()));
            }
            if let Some(c) = &o.comment {
                lines.push(format!("COMMENT {}", string(c)));
            }
            if let Some(Value::Array(libs)) = r.options.get("imports") {
                let libs: Vec<&str> = libs.iter().filter_map(Value::as_str).collect();
                lines.push(format!("USING ({})", libs.join(", ")));
            }
            for l in lines {
                let _ = write!(t, "\n    {l}");
            }
            let _ = write!(t, "\n{}", r.body);
            t
        }
        TRIGGER => {
            let tr = section.trigger.as_ref().ok_or("a trigger without its trigger")?;
            let table = s.object(&tr.table).ok_or("a trigger on a table not in the schema")?;
            let timing = match tr.timing {
                sections::Timing::Before => "BEFORE",
                sections::Timing::After => "AFTER",
                _ => return Err("MySQL's triggers run before or after a change".to_string()),
            };
            let change = match tr.events.as_slice() {
                [sections::Change::Insert] => "INSERT",
                [sections::Change::Update] => "UPDATE",
                [sections::Change::Delete] => "DELETE",
                _ => return Err("a MySQL trigger fires on one change: an insert, an update or a delete".to_string()),
            };
            if tr.condition.is_some() {
                return Err("a MySQL trigger has no WHEN condition".to_string());
            }
            let mut t =
                format!("CREATE{definer} TRIGGER {name} {timing} {change} ON {} FOR EACH ROW", qualified(s, table, o));
            if let Some(f) = text_opt(opts, "follows") {
                let _ = write!(t, " FOLLOWS {}", quote(f));
            }
            if let Some(p) = text_opt(opts, "precedes") {
                let _ = write!(t, " PRECEDES {}", quote(p));
            }
            let _ = write!(t, " {}", tr.body);
            t
        }
        EVENT => {
            let e = section.event.as_ref().ok_or("an event without its event")?;
            let mut t = format!("CREATE{definer} EVENT {name} ON SCHEDULE {} ON COMPLETION ", e.schedule);
            t.push_str(if e.preserve { "PRESERVE" } else { "NOT PRESERVE" });
            t.push_str(match (e.enabled, opts.get("disabled_on_replica") == Some(&Value::Bool(true))) {
                (true, _) => " ENABLE",
                (false, true) => " DISABLE ON REPLICA",
                (false, false) => " DISABLE",
            });
            if let Some(c) = &o.comment {
                let _ = write!(t, " COMMENT {}", string(c));
            }
            let _ = write!(t, " DO {}", e.body);
            t
        }
        LOADABLE_FUNCTION => {
            let aggregate = if opts.get("aggregate") == Some(&Value::Bool(true)) { " AGGREGATE" } else { "" };
            let returns = text_opt(opts, "returns").ok_or("a loadable function that returns nothing")?;
            let soname = text_opt(opts, "soname").ok_or("a loadable function without its library file")?;
            return Ok((
                format!("CREATE{aggregate} FUNCTION {name} RETURNS {returns} SONAME {}", string(soname)),
                false,
            ));
        }
        TABLESPACE => {
            let mut t = format!("CREATE TABLESPACE {name}");
            if let Some(f) = text_opt(opts, "datafile") {
                let _ = write!(t, " ADD DATAFILE {}", string(f));
            }
            for (key, sql, quoted) in [
                ("autoextend_size", "AUTOEXTEND_SIZE", false),
                ("file_block_size", "FILE_BLOCK_SIZE", false),
                ("encryption", "ENCRYPTION", true),
                ("engine_attribute", "ENGINE_ATTRIBUTE", true),
                ("engine", "ENGINE", false),
            ] {
                if let Some(v) = text_opt(opts, key) {
                    let _ = write!(t, " {sql}={}", if quoted { string(v) } else { v.to_string() });
                }
            }
            return Ok((t, false));
        }
        SPATIAL_REFERENCE_SYSTEM => {
            let srid = opts.get("srid").and_then(Value::as_i64).ok_or("a spatial reference system without its id")?;
            let def = text_opt(opts, "definition").ok_or("a spatial reference system without its definition")?;
            let mut t =
                format!("CREATE SPATIAL REFERENCE SYSTEM {srid} NAME {} DEFINITION {}", string(&o.name), string(def));
            if let (Some(org), Some(id)) =
                (text_opt(opts, "organization"), opts.get("organization_srid").and_then(Value::as_i64))
            {
                let _ = write!(t, " ORGANIZATION {} IDENTIFIED BY {id}", string(org));
            }
            if let Some(c) = &o.comment {
                let _ = write!(t, " DESCRIPTION {}", string(c));
            }
            return Ok((t, false));
        }
        other => return Err(format!("`{}` is a `{other}`, which MySQL does not have", o.name)),
    };
    Ok((text, true))
}

/// `CREATE TABLE`, as `SHOW CREATE TABLE` writes it.
fn table(s: &Schema, o: &Object, t: &ObjectSection) -> Result<String, String> {
    let col_name = |id: &Id| -> Result<String, String> {
        o.columns
            .iter()
            .find(|c| &c.id == id)
            .map(|c| quote(&c.name))
            .ok_or_else(|| format!("{id} is not a column of `{}`", o.name))
    };
    let links: Vec<(&schema_forge_model::Link, LinkSection)> = s
        .links
        .iter()
        .filter(|l| l.from.object == o.id)
        .map(|l| sections::read::<LinkSection>(&l.engine).map(|sec| (l, sec)))
        .collect::<Result<_, _>>()?;
    let inline = |l: &LinkSection| l.options.get("inline") == Some(&Value::Bool(true));
    let mut lines = Vec::new();
    for c in &o.columns {
        let cs: sections::ColumnSection = sections::read(&c.engine)?;
        let opts = &cs.options;
        let mut line = format!("{} {}", quote(&c.name), c.data_type);
        if let Some(v) = text_opt(opts, "charset") {
            let _ = write!(line, " CHARACTER SET {v}");
        }
        if let Some(v) = text_opt(opts, "collation") {
            let _ = write!(line, " COLLATE {v}");
        }
        if let Some(g) = &cs.generated {
            let _ =
                write!(line, " GENERATED ALWAYS AS ({}) {}", g.expression, if g.stored { "STORED" } else { "VIRTUAL" });
        }
        if !c.null {
            line.push_str(" NOT NULL");
        } else if c.data_type.starts_with("timestamp") {
            line.push_str(" NULL");
        }
        if let Some(n) = opts.get("srid").and_then(Value::as_i64) {
            let _ = write!(line, " SRID {n}");
        }
        if let Some(d) = &cs.default {
            let _ = write!(line, " DEFAULT {d}");
        }
        if let Some(u) = text_opt(opts, "on_update") {
            let _ = write!(line, " ON UPDATE {u}");
        }
        if let Some(i) = &cs.identity {
            if i.always
                || i.start.is_some()
                || i.increment.is_some()
                || i.min.is_some()
                || i.max.is_some()
                || i.cache.is_some()
                || i.cycle
            {
                return Err(format!("`{}.{}`: MySQL numbers a column with AUTO_INCREMENT only", o.name, c.name));
            }
            line.push_str(" AUTO_INCREMENT");
        }
        if let Some(cm) = &c.comment {
            let _ = write!(line, " COMMENT {}", string(cm));
        }
        if opts.get("invisible") == Some(&Value::Bool(true)) {
            line.push_str(" INVISIBLE");
        }
        for (key, sql) in [("column_format", "COLUMN_FORMAT"), ("storage", "STORAGE")] {
            if let Some(v) = text_opt(opts, key) {
                let _ = write!(line, " {sql} {v}");
            }
        }
        for (key, sql) in
            [("engine_attribute", "ENGINE_ATTRIBUTE"), ("secondary_engine_attribute", "SECONDARY_ENGINE_ATTRIBUTE")]
        {
            if let Some(v) = text_opt(opts, key) {
                let _ = write!(line, " {sql}={}", string(v));
            }
        }
        for (l, sec) in links.iter().filter(|(l, sec)| inline(sec) && l.from.columns == [c.id.clone()]) {
            let _ = write!(line, " {}", references(s, o, l, sec)?);
        }
        lines.push(line);
    }
    if let Some(k) = &t.keys.primary {
        lines.push(format!("PRIMARY KEY {}", key(k, &col_name)?));
    }
    for k in &t.keys.unique {
        let name = k.name.as_deref().map(|n| format!("{} ", quote(n))).unwrap_or_default();
        lines.push(format!("UNIQUE KEY {name}{}", key(k, &col_name)?));
    }
    for i in &t.indexes {
        lines.push(index(i, &col_name)?);
    }
    for (l, sec) in &links {
        if inline(sec) {
            if l.from.columns.len() != 1 {
                return Err("a link written on its column has one column".to_string());
            }
            continue;
        }
        if !sec.enforced {
            return Err(format!(
                "`{}`: a link MySQL does not enforce can only be written on its column, and from 9.0 MySQL enforces those",
                o.name
            ));
        }
        let cols: Vec<String> = l.from.columns.iter().map(&col_name).collect::<Result<_, _>>()?;
        let name = l.name.as_deref().map(|n| format!("CONSTRAINT {} ", quote(n))).unwrap_or_default();
        lines.push(format!("{name}FOREIGN KEY ({}) {}", cols.join(","), references(s, o, l, sec)?));
    }
    if let Some(Value::Array(outside)) = t.options.get("outside_references") {
        lines.extend(outside.iter().filter_map(Value::as_str).map(str::to_string));
    }
    for c in &t.checks {
        let name = c.name.as_deref().map(|n| format!("CONSTRAINT {} ", quote(n))).unwrap_or_default();
        let not = if c.options.get("not_enforced") == Some(&Value::Bool(true)) { " NOT ENFORCED" } else { "" };
        lines.push(format!("{name}CHECK ({}){not}", c.expression));
    }
    let mut out = format!("CREATE TABLE {} (\n  {}\n)", quote(&o.name), lines.join(",\n  "));
    out.push_str(&table_options(&t.options, o.comment.as_deref()));
    if let Some(p) = &t.partitioning {
        out.push('\n');
        out.push_str(&partitioning(p, &col_name)?);
    }
    Ok(out)
}

/// `REFERENCES parent (columns) …`.
fn references(s: &Schema, o: &Object, l: &schema_forge_model::Link, sec: &LinkSection) -> Result<String, String> {
    let parent = s.object(&l.to.object).ok_or("a link to an object not in the schema")?;
    let cols: Vec<String> =
        l.to.columns
            .iter()
            .map(|id| {
                parent
                    .columns
                    .iter()
                    .find(|c| &c.id == id)
                    .map(|c| quote(&c.name))
                    .ok_or("a link to a column not in the schema")
            })
            .collect::<Result<_, _>>()?;
    let mut t = format!("REFERENCES {} ({})", qualified(s, parent, o), cols.join(","));
    if let Some(m) = &sec.match_kind {
        let _ = write!(t, " MATCH {}", m.to_ascii_uppercase());
    }
    if let Some(a) = sec.on_delete {
        let _ = write!(t, " ON DELETE {}", action(a));
    }
    if let Some(a) = sec.on_update {
        let _ = write!(t, " ON UPDATE {}", action(a));
    }
    if sec.deferrable.is_some() {
        return Err("MySQL checks a foreign key at once, never at the end of a transaction".to_string());
    }
    Ok(t)
}

fn action(a: Action) -> &'static str {
    match a {
        Action::Restrict => "RESTRICT",
        Action::Cascade => "CASCADE",
        Action::SetNull => "SET NULL",
        Action::SetDefault => "SET DEFAULT",
        _ => "NO ACTION",
    }
}

/// An object's name as another object in `from`'s database writes it.
fn qualified(s: &Schema, o: &Object, from: &Object) -> String {
    if o.namespace == from.namespace {
        return quote(&o.name);
    }
    let db = s.namespace(&o.namespace).map(|n| n.name.as_str()).unwrap_or_default();
    format!("{}.{}", quote(db), quote(&o.name))
}

/// A key's parts and options: `(a,b(10) DESC) USING BTREE COMMENT '…'`.
fn key(k: &Key, col_name: &dyn Fn(&Id) -> Result<String, String>) -> Result<String, String> {
    let shapes: Vec<Value> = match k.options.get("parts") {
        Some(Value::Array(a)) => a.clone(),
        _ => Vec::new(),
    };
    let mut parts = Vec::new();
    for (n, c) in k.columns.iter().enumerate() {
        let mut p = col_name(c)?;
        if let Some(shape) = shapes.get(n) {
            if let Some(l) = shape.get("length").and_then(Value::as_i64) {
                let _ = write!(p, "({l})");
            }
            if shape.get("desc") == Some(&Value::Bool(true)) {
                p.push_str(" DESC");
            }
        }
        parts.push(p);
    }
    let mut t = format!("({})", parts.join(","));
    if let Some(m) = text_opt(&k.options, "method") {
        let _ = write!(t, " USING {m}");
    }
    t.push_str(&index_options(&k.options));
    Ok(t)
}

fn index(i: &Index, col_name: &dyn Fn(&Id) -> Result<String, String>) -> Result<String, String> {
    if i.condition.is_some() || !i.include.is_empty() {
        return Err(format!("`{}`: a MySQL index has no WHERE and no INCLUDE", i.name));
    }
    let kind = match (i.unique, i.method.as_deref()) {
        (_, Some("fulltext")) => "FULLTEXT KEY",
        (_, Some("spatial")) => "SPATIAL KEY",
        (true, _) => "UNIQUE KEY",
        _ => "KEY",
    };
    let mut parts = Vec::new();
    for p in &i.parts {
        let mut text = match (&p.column, &p.expression) {
            (Some(c), None) => col_name(c)?,
            (None, Some(e)) => format!("({e})"),
            _ => return Err(format!("`{}`: a part is one column or one expression", i.name)),
        };
        if let Some(l) = p.options.get("length").and_then(Value::as_i64) {
            let _ = write!(text, "({l})");
        }
        if p.direction == Some(Direction::Desc) {
            text.push_str(" DESC");
        }
        if p.nulls.is_some() {
            return Err(format!("`{}`: MySQL puts nulls first, always", i.name));
        }
        parts.push(text);
    }
    let mut t = format!("{kind} {} ({})", quote(&i.name), parts.join(","));
    match i.method.as_deref() {
        Some(m @ ("btree" | "hash")) => {
            let _ = write!(t, " USING {}", m.to_ascii_uppercase());
        }
        None | Some("fulltext" | "spatial") => {}
        Some(m) => return Err(format!("`{}`: MySQL has no `{m}` index", i.name)),
    }
    t.push_str(&index_options(&i.options));
    Ok(t)
}

fn index_options(o: &Options) -> String {
    let mut t = String::new();
    if let Some(n) = o.get("key_block_size").and_then(Value::as_i64) {
        let _ = write!(t, " KEY_BLOCK_SIZE={n}");
    }
    if let Some(p) = text_opt(o, "parser") {
        let _ = write!(t, " WITH PARSER {}", quote(p));
    }
    if let Some(c) = text_opt(o, "comment") {
        let _ = write!(t, " COMMENT {}", string(c));
    }
    if o.get("invisible") == Some(&Value::Bool(true)) {
        t.push_str(" INVISIBLE");
    }
    if let Some(e) = text_opt(o, "engine_attribute") {
        let _ = write!(t, " ENGINE_ATTRIBUTE={}", string(e));
    }
    t
}

/// The table's options, in the order `SHOW CREATE TABLE` writes them, then its comment.
fn table_options(o: &Options, comment: Option<&str>) -> String {
    const ORDER: &[(&str, &str, bool)] = &[
        ("engine", "ENGINE", false),
        ("auto_increment", "AUTO_INCREMENT", false),
        ("charset", "DEFAULT CHARSET", false),
        ("collation", "COLLATE", false),
        ("avg_row_length", "AVG_ROW_LENGTH", false),
        ("checksum", "CHECKSUM", false),
        ("compression", "COMPRESSION", true),
        ("connection", "CONNECTION", true),
        ("data_directory", "DATA DIRECTORY", true),
        ("index_directory", "INDEX DIRECTORY", true),
        ("delay_key_write", "DELAY_KEY_WRITE", false),
        ("encryption", "ENCRYPTION", true),
        ("engine_attribute", "ENGINE_ATTRIBUTE", true),
        ("secondary_engine", "SECONDARY_ENGINE", false),
        ("secondary_engine_attribute", "SECONDARY_ENGINE_ATTRIBUTE", true),
        ("insert_method", "INSERT_METHOD", false),
        ("key_block_size", "KEY_BLOCK_SIZE", false),
        ("max_rows", "MAX_ROWS", false),
        ("min_rows", "MIN_ROWS", false),
        ("pack_keys", "PACK_KEYS", false),
        ("stats_auto_recalc", "STATS_AUTO_RECALC", false),
        ("stats_persistent", "STATS_PERSISTENT", false),
        ("stats_sample_pages", "STATS_SAMPLE_PAGES", false),
        ("row_format", "ROW_FORMAT", false),
        ("autoextend_size", "AUTOEXTEND_SIZE", false),
    ];
    let mut t = String::new();
    if let Some(ts) = text_opt(o, "tablespace") {
        let _ = write!(t, " TABLESPACE {}", quote(ts));
    }
    for (key, sql, quoted) in ORDER {
        match o.get(*key) {
            Some(Value::String(v)) => {
                let _ = write!(t, " {sql}={}", if *quoted { string(v) } else { v.clone() });
            }
            Some(Value::Number(n)) => {
                let _ = write!(t, " {sql}={n}");
            }
            _ => {}
        }
    }
    if let Some(Value::Array(tables)) = o.get("union") {
        let names: Vec<String> = tables.iter().filter_map(Value::as_str).map(quote).collect();
        let _ = write!(t, " UNION=({})", names.join(","));
    }
    if let Some(c) = comment {
        let _ = write!(t, " COMMENT={}", string(c));
    }
    t
}

fn partitioning(
    p: &sections::Partitioning,
    col_name: &dyn Fn(&Id) -> Result<String, String>,
) -> Result<String, String> {
    let o = &p.options;
    let flag = |k: &str| o.get(k) == Some(&Value::Bool(true));
    let strategy = p.strategy.as_deref().ok_or("partitioning without its way of splitting")?;
    let by: Vec<String> =
        p.by.iter()
            .map(|f| match (&f.column, &f.expression) {
                (Some(c), None) => col_name(c),
                (None, Some(e)) => Ok(e.clone()),
                _ => Err("a partitioning field is one column or one expression".to_string()),
            })
            .collect::<Result<_, _>>()?;
    let mut t =
        format!("PARTITION BY {}{}", if flag("linear") { "LINEAR " } else { "" }, strategy.to_ascii_uppercase());
    if let Some(a) = o.get("algorithm").and_then(Value::as_i64) {
        let _ = write!(t, " ALGORITHM = {a}");
    }
    if flag("columns") {
        t.push_str(" COLUMNS");
    }
    let _ = write!(t, " ({})", by.join(","));
    if let Some(n) = o.get("count").and_then(Value::as_i64) {
        let _ = write!(t, "\nPARTITIONS {n}");
    }
    if let Some(sub) = o.get("subpartition") {
        let get = |k: &str| sub.get(k);
        let linear = if get("linear") == Some(&Value::Bool(true)) { "LINEAR " } else { "" };
        let strategy = get("strategy").and_then(Value::as_str).ok_or("subpartitioning without its way")?;
        let _ = write!(t, "\nSUBPARTITION BY {linear}{}", strategy.to_ascii_uppercase());
        if let Some(a) = get("algorithm").and_then(Value::as_i64) {
            let _ = write!(t, " ALGORITHM = {a}");
        }
        let _ = write!(t, " ({})", get("by").and_then(Value::as_str).unwrap_or_default());
        if let Some(n) = get("count").and_then(Value::as_i64) {
            let _ = write!(t, "\nSUBPARTITIONS {n}");
        }
    }
    if !p.partitions.is_empty() {
        let parts: Vec<String> = p
            .partitions
            .iter()
            .map(|x| {
                let mut s = format!("PARTITION {}", quote(&x.name));
                if !x.bounds.is_empty() {
                    let _ = write!(s, " {}", x.bounds);
                }
                s.push_str(&partition_options(&x.options));
                if let Some(Value::Array(subs)) = x.options.get("subpartitions") {
                    let subs: Vec<String> = subs
                        .iter()
                        .filter_map(Value::as_object)
                        .map(|sub| {
                            let name = sub.get("name").and_then(Value::as_str).unwrap_or_default();
                            format!("SUBPARTITION {}{}", quote(name), partition_options(sub))
                        })
                        .collect();
                    let _ = write!(s, " ({})", subs.join(", "));
                }
                s
            })
            .collect();
        let _ = write!(t, "\n({})", parts.join(",\n "));
    }
    Ok(t)
}

fn partition_options(o: &Options) -> String {
    let mut t = String::new();
    for (key, sql, quoted) in [
        ("comment", "COMMENT", true),
        ("data_directory", "DATA DIRECTORY", true),
        ("index_directory", "INDEX DIRECTORY", true),
        ("max_rows", "MAX_ROWS", false),
        ("min_rows", "MIN_ROWS", false),
        ("tablespace", "TABLESPACE", false),
        ("engine", "ENGINE", false),
    ] {
        match o.get(key) {
            Some(Value::String(v)) => {
                let _ = write!(t, " {sql} = {}", if quoted { string(v) } else { v.clone() });
            }
            Some(Value::Number(n)) => {
                let _ = write!(t, " {sql} = {n}");
            }
            _ => {}
        }
    }
    t
}

fn database_options(o: &Options) -> String {
    let mut t = String::new();
    if let Some(c) = text_opt(o, "charset") {
        let _ = write!(t, " DEFAULT CHARACTER SET {c}");
    }
    if let Some(c) = text_opt(o, "collation") {
        let _ = write!(t, " COLLATE {c}");
    }
    if let Some(Value::Bool(e)) = o.get("encryption") {
        let _ = write!(t, " DEFAULT ENCRYPTION='{}'", if *e { "Y" } else { "N" });
    }
    if let Some(Value::Bool(r)) = o.get("read_only") {
        let _ = write!(t, " READ ONLY = {}", u8::from(*r));
    }
    t
}

/// A kept statement, written back as it was read.
fn kept(k: &Kept) -> String {
    if k.text.contains(';') { format!("DELIMITER ;;\n{} ;;\nDELIMITER ;\n", k.text) } else { format!("{};\n", k.text) }
}

fn text_opt<'a>(o: &'a Options, key: &str) -> Option<&'a str> {
    o.get(key).and_then(Value::as_str)
}

/// A name in backquotes.
#[must_use]
pub fn quote(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}

/// A string in single quotes, as MySQL reads one by default.
#[must_use]
pub fn string(s: &str) -> String {
    format!("'{}'", s.replace('\\', "\\\\").replace('\'', "''"))
}
