//! Reading MySQL's SQL into a schema: a `mysqldump` file, hand-written DDL, or what `SHOW CREATE …` gives for each
//! object of a live database. Every statement is modelled, kept as written by kind, counted as data, or counted as the
//! dump's own machinery; the report adds up.

pub mod program;
pub mod server;
pub mod table;

use std::collections::{BTreeMap, HashMap};

use schema_forge_engine::sections::{
    self, IndexPart, Kept, Key, LinkSection, NamespaceSection, ObjectSection, Options, PartField, Partitioning,
    SchemaSection, Trigger,
};
use schema_forge_engine::{Imported, Input, Report, Unread};
use schema_forge_model::{Column, Ends, Id, Ids, Kind, Link, Namespace, Object, Schema};
use serde_json::{Value, json};
use sqlparser::tokenizer::Token;

use crate::dump::{self, Statement};
use crate::kinds::{
    EVENT, FUNCTION, LIBRARY, LOADABLE_FUNCTION, PROCEDURE, SPATIAL_REFERENCE_SYSTEM, TABLE, TABLESPACE, TRIGGER, VIEW,
};
use crate::lex::Cursor;
use crate::types::Family;
use crate::versions::{self, VERSIONS};

/// The first line of a schema this engine writes, before its version.
pub const HEADER: &str = "-- MySQL";
/// What follows the version in that line.
pub const HEADER_TAIL: &str = "schema, written by Schema Forge";
/// The database objects go in when a file names none.
pub const DEFAULT_DATABASE: &str = "default";

/// Whether `input` is MySQL's SQL: a `mysqldump` file, a schema this engine wrote, or DDL only MySQL writes.
#[must_use]
pub fn recognises(input: &Input) -> bool {
    if input.is_dir {
        return false;
    }
    if is_mariadb(&input.head) {
        return false;
    }
    let first = input.head.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    if first.starts_with("-- MySQL dump") || written_version(first).is_some() {
        return true;
    }
    // DDL, with something only MySQL writes: backquotes, table options, versioned comments, the client's DELIMITER,
    // or the server version a person names in a comment.
    let head = input.head.to_ascii_lowercase();
    let ddl = ["create table", "create database", "create procedure", "create function", "create library"]
        .iter()
        .any(|w| head.contains(w));
    let mysql = ["`", "engine=", "/*!", "auto_increment", "\ndelimiter ", "-- server version", "language javascript"]
        .iter()
        .any(|w| head.contains(w));
    ddl && mysql
}

/// The version a schema this engine wrote names in its first line.
fn written_version(line: &str) -> Option<&'static str> {
    let v = line.strip_prefix(HEADER)?.strip_suffix(HEADER_TAIL)?.trim();
    VERSIONS.iter().find(|x| x.id == v).map(|x| x.id)
}

/// The engine version a file is read at: the one it names, the one its server's version falls in, or the default.
#[must_use]
pub fn version_of(head: &str) -> &'static str {
    let first = head.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    if let Some(v) = written_version(first) {
        return v;
    }
    head.lines().find_map(|l| l.strip_prefix("-- Server version")).map_or(versions::DEFAULT, |v| version_for(v.trim()))
}

/// The engine version a server of version `server` (`9.7.4`, `8.0.46-log`) is designed for: the first of the engine's
/// versions not older than it, or the newest.
#[must_use]
pub fn version_for(server: &str) -> &'static str {
    let num = |s: &str| -> (u32, u32) {
        let mut parts =
            s.split(|c: char| !c.is_ascii_digit()).filter(|p| !p.is_empty()).map(|p| p.parse().unwrap_or(0));
        (parts.next().unwrap_or(0), parts.next().unwrap_or(0))
    };
    let at = num(server);
    VERSIONS.iter().find(|v| num(v.id) >= at).or(VERSIONS.last()).map_or(versions::DEFAULT, |v| v.id)
}

/// Reads `text`, MySQL's SQL, at `version`.
///
/// # Errors
/// When it is not MySQL's to read: a MariaDB dump, or statements made under `NO_BACKSLASH_ESCAPES`, whose strings
/// this reader would misread.
pub fn read(families: &[Family], text: String, version: &str) -> Result<Imported, String> {
    let head: String = text.chars().take(64 * 1024).collect();
    if is_mariadb(&head) {
        return Err("this is MariaDB's: MariaDB is not MySQL, and needs an engine of its own".to_string());
    }
    let open = dump::unwrap(text);
    let mut b = Builder::new(families, version);
    for s in dump::statements(&open) {
        b.statement(&s);
    }
    b.finish()
}

/// Whether a file is MariaDB's, by what MariaDB writes at its top: its dump header (or MySQL's header naming a MariaDB
/// distribution), its own versioned comment (`/*M!…*/`) on a line of its own, or a server version that says so. What
/// a row holds never counts.
#[must_use]
pub fn is_mariadb(text: &str) -> bool {
    let mariadb = |l: &str| l.to_ascii_lowercase().contains("mariadb");
    text.lines().take(5).any(|l| {
        l.starts_with("-- MariaDB dump") || (l.starts_with("-- MySQL dump") && mariadb(l)) || l.starts_with("/*M!")
    }) || text.lines().any(|l| l.starts_with("-- Server version") && mariadb(l))
}

/// What a dump sets before a stored program, and so the program was made with.
const SETTINGS: &[&str] = &["sql_mode", "character_set_client", "collation_connection", "time_zone"];

/// A foreign key waiting for every table to be read: dumps write a table before the tables it refers to.
struct PendingLink {
    from: Id,
    columns: Vec<Id>,
    fk: table::Fk,
}

struct Builder<'f> {
    families: &'f [Family],
    version: String,
    schema: Schema,
    ids: Ids,
    report: Report,
    kept: Vec<Kept>,
    current: Option<Id>,
    settings: BTreeMap<&'static str, String>,
    /// Whether a statement was made under `NO_BACKSLASH_ESCAPES`, in which a backslash is not an escape.
    no_backslash_escapes: bool,
    /// The part the next kept statement goes after.
    last: Option<Id>,
    /// How many statements made each object, to count them again when it is dropped.
    made_by: HashMap<Id, usize>,
    /// The ids of objects dropped, by namespace, kind and name: an object of that kind made again under the same name
    /// keeps its id.
    freed: HashMap<(Id, String, String), Id>,
    links: Vec<PendingLink>,
}

/// What a statement became.
enum Done {
    Modelled(Option<Id>),
    Kept(&'static str),
    /// Kept, of this kind, as this text: a statement without its credentials.
    Cut(&'static str, String),
    Data,
    Machinery,
}

impl<'f> Builder<'f> {
    fn new(families: &'f [Family], version: &str) -> Self {
        Self {
            families,
            version: version.to_string(),
            schema: Schema::new("mysql", version),
            ids: Ids::default(),
            report: Report::new("statements"),
            kept: Vec::new(),
            current: None,
            settings: BTreeMap::new(),
            no_backslash_escapes: false,
            last: None,
            made_by: HashMap::new(),
            freed: HashMap::new(),
            links: Vec::new(),
        }
    }

    fn statement(&mut self, s: &Statement<'_>) {
        self.report.read += 1;
        // Rows, by their first word: a dump's are most of it, and are never tokenised.
        let first = s.text.split(|c: char| !c.is_ascii_alphabetic()).next().unwrap_or("");
        if first.eq_ignore_ascii_case("INSERT") || first.eq_ignore_ascii_case("REPLACE") {
            self.report.data += 1;
            return;
        }
        let outcome = Cursor::new(s.text).and_then(|mut c| self.classify(&mut c, s));
        match outcome {
            Ok(Done::Modelled(id)) => {
                self.report.modelled += 1;
                if let Some(id) = id {
                    *self.made_by.entry(id.clone()).or_default() += 1;
                    self.last = Some(id);
                }
            }
            Ok(Done::Kept(kind)) => self.keep(kind, s.text),
            Ok(Done::Cut(kind, text)) => self.keep(kind, &text),
            Ok(Done::Data) => self.report.data += 1,
            Ok(Done::Machinery) => self.report.machinery += 1,
            Err(why) => self.not_understood(s, &why),
        }
    }

    fn keep(&mut self, kind: &'static str, text: &str) {
        let mut k = Kept::default();
        k.kind = kind.to_string();
        k.text = text.to_string();
        k.after = self.last.clone();
        self.kept.push(k);
        *self.report.kept.entry(kind.to_string()).or_default() += 1;
    }

    fn not_understood(&mut self, s: &Statement<'_>, why: &str) {
        self.keep("other", s.text);
        let start: String = s.text.lines().next().unwrap_or("").chars().take(100).collect();
        self.report.not_understood.push(Unread::new(format!("line {}: {why}", s.line), start));
    }

    fn classify(&mut self, c: &mut Cursor<'_>, s: &Statement<'_>) -> Result<Done, String> {
        if c.eat_kw("CREATE") {
            return self.create(c, s);
        }
        if c.peek_kw("INSERT") || c.peek_kw("REPLACE") || c.eat_kws(&["LOAD", "DATA"]) {
            return Ok(Done::Data);
        }
        if c.peek_kw("GRANT") || c.peek_kw("REVOKE") {
            return Ok(credentials(s.text, "grant", false));
        }
        // A password is never kept: setting one is left out with the data, and an account is kept without it.
        if c.eat_kws(&["SET", "PASSWORD"]) {
            return Ok(Done::Data);
        }
        if c.peek_kw("ALTER") && c.peek_kw_at(1, "USER") {
            return Ok(credentials(s.text, "account", true));
        }
        if c.eat_kws(&["SET", "DEFAULT", "ROLE"]) || c.eat_kws(&["RENAME", "USER"]) {
            return Ok(Done::Kept("account"));
        }
        if c.eat_kw("SET") {
            self.set(c);
            return Ok(Done::Machinery);
        }
        if c.eat_kw("USE") {
            let name = c.name()?;
            let ns = self.namespace(Some(&name));
            // What is kept after a switch of database is written back in that database.
            if self.current.as_ref() != Some(&ns) {
                self.last = Some(ns.clone());
            }
            self.current = Some(ns);
            return Ok(Done::Machinery);
        }
        if c.eat_kw("DROP") {
            return self.drop(c);
        }
        if c.eat_kws(&["ALTER", "TABLE"]) {
            c.qualified()?;
            if (c.eat_kw("DISABLE") || c.eat_kw("ENABLE")) && c.eat_kw("KEYS") && c.is_done() {
                return Ok(Done::Machinery);
            }
            return Err("an ALTER TABLE is kept as written".to_string());
        }
        const MACHINERY: &[&[&str]] = &[
            &["LOCK", "TABLES"],
            &["LOCK", "TABLE"],
            &["UNLOCK", "TABLES"],
            &["FLUSH"],
            &["START", "TRANSACTION"],
            &["COMMIT"],
            &["CHANGE", "REPLICATION"],
            &["CHANGE", "MASTER"],
        ];
        if MACHINERY.iter().any(|words| c.eat_kws(words)) {
            return Ok(Done::Machinery);
        }
        Err("not a statement this reader knows".to_string())
    }

    fn create(&mut self, c: &mut Cursor<'_>, s: &Statement<'_>) -> Result<Done, String> {
        if c.peek_kw("USER") {
            return Ok(credentials(s.text, "account", true));
        }
        if c.eat_kw("ROLE") {
            return Ok(Done::Kept("account"));
        }
        if c.eat_kws(&["RESOURCE", "GROUP"]) {
            return Ok(Done::Kept("resource_group"));
        }
        if c.peek_kw("SERVER") {
            return Ok(credentials(s.text, "server", false));
        }
        if c.eat_kw("DATABASE") || c.eat_kw("SCHEMA") {
            let (name, options) = server::database(c)?;
            let id = self.namespace(Some(&name));
            if let Some(n) = self.schema.namespaces.iter_mut().find(|n| n.id == id) {
                let mut section: NamespaceSection = sections::read(&n.engine)?;
                section.options.extend(options);
                sort(&mut section.options);
                n.engine = sections::write(&section);
            }
            return Ok(Done::Modelled(Some(id)));
        }
        if c.eat_kw("TABLESPACE") {
            let (name, options) = server::tablespace(c)?;
            let id = self.object(TABLESPACE, None, &name, None, with!(ObjectSection { options: options }))?;
            return Ok(Done::Modelled(Some(id)));
        }
        if c.eat_kws(&["SPATIAL", "REFERENCE", "SYSTEM"]) {
            let srs = server::srs(c)?;
            let section = with!(ObjectSection { options: srs.options });
            let id = self.object(SPATIAL_REFERENCE_SYSTEM, None, &srs.name, srs.description, section)?;
            return Ok(Done::Modelled(Some(id)));
        }
        if c.peek_kw("UNIQUE") || c.peek_kw("FULLTEXT") || c.peek_kw("SPATIAL") || c.peek_kw("INDEX") {
            let kind = ["UNIQUE", "FULLTEXT", "SPATIAL"].into_iter().find(|k| c.eat_kw(k));
            c.expect_kw("INDEX")?;
            let (table, index) = table::create_index(c, kind)?;
            return self.add_index(&table, index).map(|id| Done::Modelled(Some(id)));
        }
        let head = program::head(c)?;
        if c.eat_kw("TABLE") {
            let t = table::create_table(c, self.families, &self.version)?;
            return self.add_table(t).map(|id| Done::Modelled(Some(id)));
        }
        if c.eat_kw("VIEW") {
            let v = program::view(c, head)?;
            let mut section = with!(ObjectSection { query: Some(v.query), options: v.options });
            self.with_settings(VIEW, &mut section.options);
            // A view made again replaces the one before it: a dump's placeholder, or `CREATE OR REPLACE`.
            let ns = self.namespace(v.db.as_deref());
            if let Some(old) = self.find(&ns, &v.name, &[VIEW]) {
                self.remove(&old)?;
            }
            let id = self.object(VIEW, v.db.as_deref(), &v.name, None, section)?;
            return Ok(Done::Modelled(Some(id)));
        }
        if c.eat_kw("PROCEDURE") || c.peek_kw("FUNCTION") {
            let function = c.eat_kw("FUNCTION");
            let mark = c.mark();
            c.eat_kws(&["IF", "NOT", "EXISTS"]);
            let (db, name) = c.qualified()?;
            if function && !matches!(c.peek(), Some(Token::LParen)) {
                let options = program::loadable(c, head.aggregate)?;
                let section = with!(ObjectSection { options: options });
                let id = self.object(LOADABLE_FUNCTION, db.as_deref(), &name, None, section)?;
                return Ok(Done::Modelled(Some(id)));
            }
            c.reset(mark);
            let p = program::routine(c, head, function)?;
            let kind = if function { FUNCTION } else { PROCEDURE };
            return self.add_program(kind, p).map(|id| Done::Modelled(Some(id)));
        }
        if c.eat_kw("LIBRARY") {
            let p = program::library(c, head)?;
            return self.add_program(LIBRARY, p).map(|id| Done::Modelled(Some(id)));
        }
        if c.eat_kw("TRIGGER") {
            let t = program::trigger(c, head)?;
            // MySQL makes a trigger only on a table there already: a trigger whose table is not in the schema is
            // kept as written, in its place.
            let named = |db: &str| self.schema.namespaces.iter().find(|n| n.name == db).map(|n| n.id.clone());
            let ns = match (&t.table.0, &t.db) {
                (Some(db), _) | (None, Some(db)) => named(db),
                (None, None) => self.current.clone(),
            };
            let table = ns
                .and_then(|ns| self.find(&ns, &t.table.1, &[TABLE]))
                .ok_or_else(|| format!("its table `{}` is not in the schema", t.table.1))?;
            let trigger = Trigger::new(t.timing, vec![t.change], table, t.body);
            let mut section = with!(ObjectSection { trigger: Some(trigger), options: t.options });
            self.with_settings(TRIGGER, &mut section.options);
            let id = self.object(TRIGGER, t.db.as_deref(), &t.name, None, section)?;
            return Ok(Done::Modelled(Some(id)));
        }
        if c.eat_kw("EVENT") {
            let e = program::event(c, head)?;
            let mut section = with!(ObjectSection { event: Some(e.event), options: e.options });
            self.with_settings(EVENT, &mut section.options);
            let id = self.object(EVENT, e.db.as_deref(), &e.name, e.comment, section)?;
            return Ok(Done::Modelled(Some(id)));
        }
        Err("not a CREATE this reader knows".to_string())
    }

    /// The settings in effect, on an object of `kind` made under them: those MySQL stores with it.
    fn with_settings(&self, kind: &str, options: &mut Options) {
        for (key, value) in &self.settings {
            let stored = match *key {
                "character_set_client" | "collation_connection" => {
                    [VIEW, PROCEDURE, FUNCTION, TRIGGER, EVENT].contains(&kind)
                }
                "sql_mode" => [PROCEDURE, FUNCTION, TRIGGER, EVENT].contains(&kind),
                "time_zone" => kind == EVENT,
                _ => false,
            };
            if stored {
                options.insert((*key).to_string(), json!(value));
            }
        }
    }

    /// `SET a = …, b = …`: the settings a stored program is made under, as set; a setting restored from a variable is
    /// no longer known.
    fn set(&mut self, c: &mut Cursor<'_>) {
        let mut groups = vec![(c.mark(), c.mark())];
        let mut depth = 0;
        while let Some(t) = c.peek() {
            match t {
                Token::LParen => depth += 1,
                Token::RParen => depth -= 1,
                Token::Comma if depth == 0 => {
                    let at = c.mark();
                    if let Some(g) = groups.last_mut() {
                        g.1 = at;
                    }
                    c.next();
                    groups.push((c.mark(), c.mark()));
                    continue;
                }
                _ => {}
            }
            c.next();
        }
        let end = c.len();
        if let Some(g) = groups.last_mut() {
            g.1 = end;
        }
        for (from, to) in groups {
            let text = c.slice(from, to);
            let Some((lhs, rhs)) = text.split_once('=') else { continue };
            let mut name = lhs.trim().trim_end_matches(':').trim().to_ascii_lowercase();
            if name.starts_with('@') && !name.starts_with("@@") {
                continue;
            }
            name = name.trim_start_matches("@@").to_string();
            for scope in ["session.", "local.", "global.", "session ", "local ", "global "] {
                if let Some(rest) = name.strip_prefix(scope) {
                    name = rest.trim().to_string();
                }
            }
            let Some(key) = SETTINGS.iter().find(|k| **k == name) else { continue };
            let rhs = rhs.trim();
            if rhs.starts_with('@') || rhs.contains('(') {
                self.settings.remove(key);
            } else {
                let v = rhs
                    .strip_prefix('\'')
                    .and_then(|x| x.strip_suffix('\''))
                    .map_or(rhs.to_string(), |x| x.replace("''", "'"));
                if *key == "sql_mode" && v.to_ascii_uppercase().contains("NO_BACKSLASH_ESCAPES") {
                    self.no_backslash_escapes = true;
                }
                self.settings.insert(key, v);
            }
        }
    }

    /// `DROP …`: a dump drops what it is about to make, and makes a view's placeholder before the view; what is
    /// dropped is taken out of the schema, and the statements that made it counted as machinery.
    fn drop(&mut self, c: &mut Cursor<'_>) -> Result<Done, String> {
        if c.eat_kw("USER") || c.eat_kw("ROLE") {
            return Ok(Done::Kept("account"));
        }
        if c.eat_kw("SERVER") {
            return Ok(Done::Kept("server"));
        }
        if c.eat_kws(&["RESOURCE", "GROUP"]) {
            return Ok(Done::Kept("resource_group"));
        }
        c.eat_kw("TEMPORARY");
        let kinds: &[&str] = if c.eat_kw("TABLE") || c.eat_kw("TABLES") {
            &[TABLE]
        } else if c.eat_kw("VIEW") {
            &[VIEW]
        } else if c.eat_kw("PROCEDURE") {
            &[PROCEDURE]
        } else if c.eat_kw("FUNCTION") {
            &[FUNCTION, LOADABLE_FUNCTION]
        } else if c.eat_kw("EVENT") {
            &[EVENT]
        } else if c.eat_kw("TRIGGER") {
            &[TRIGGER]
        } else if c.eat_kw("LIBRARY") {
            &[LIBRARY]
        } else if c.eat_kw("TABLESPACE") {
            &[TABLESPACE]
        } else if c.eat_kw("DATABASE") || c.eat_kw("SCHEMA") {
            let if_exists = c.eat_kws(&["IF", "EXISTS"]);
            let name = c.name()?;
            let there = self.schema.namespaces.iter().any(|n| n.name == name);
            return if !there && if_exists {
                Ok(Done::Machinery)
            } else {
                Err("a DROP DATABASE is kept as written".into())
            };
        } else {
            return Err("a DROP of this kind is kept as written".to_string());
        };
        c.eat_kws(&["IF", "EXISTS"]);
        loop {
            let (db, name) = c.qualified()?;
            let ns = match db.as_deref() {
                Some(d) => self.schema.namespaces.iter().find(|n| n.name == d).map(|n| n.id.clone()),
                None => self.current.clone(),
            };
            if let Some(old) = ns.and_then(|ns| self.find(&ns, &name, kinds)) {
                self.remove(&old)?;
            }
            if !c.eat(&Token::Comma) {
                break;
            }
        }
        c.eat_kw("RESTRICT");
        c.eat_kw("CASCADE");
        Ok(Done::Machinery)
    }

    /// Takes an object out of the schema, counting the statements that made it as machinery.
    fn remove(&mut self, id: &Id) -> Result<(), String> {
        let Some(at) = self.schema.objects.iter().position(|o| &o.id == id) else { return Ok(()) };
        let o = &self.schema.objects[at];
        let a_trigger_on_it = self.schema.objects.iter().any(|x| {
            sections::read::<ObjectSection>(&x.engine).is_ok_and(|s| s.trigger.is_some_and(|t| &t.table == id))
        });
        if a_trigger_on_it || self.links.iter().any(|l| l.fk.parent == o.name || &l.from == id) {
            return Err(format!("`{}` is dropped while something refers to it", o.name));
        }
        let before = if at > 0 { Some(self.schema.objects[at - 1].id.clone()) } else { Some(o.namespace.clone()) };
        let made = self.made_by.remove(id).unwrap_or(1);
        self.report.modelled -= made;
        self.report.machinery += made;
        for k in &mut self.kept {
            if k.after.as_ref() == Some(id) {
                k.after.clone_from(&before);
            }
        }
        if self.last.as_ref() == Some(id) {
            self.last = before;
        }
        let gone = self.schema.objects.remove(at);
        self.freed.insert((gone.namespace, gone.kind, gone.name), gone.id);
        Ok(())
    }

    /// The namespace called `name`, made when it is not there; with no name, the current one, or the default.
    fn namespace(&mut self, name: Option<&str>) -> Id {
        let name = match name {
            Some(n) => n.to_string(),
            None => match &self.current {
                Some(id) => return id.clone(),
                None => DEFAULT_DATABASE.to_string(),
            },
        };
        if let Some(n) = self.schema.namespaces.iter().find(|n| n.name == name) {
            return n.id.clone();
        }
        let id = self.ids.next(Kind::Namespace, &[&name]);
        self.schema.namespaces.push(Namespace::new(id.clone(), name));
        if self.current.is_none() {
            self.current = Some(id.clone());
        }
        id
    }

    /// An object of one of `kinds` called `name` in `ns`.
    fn find(&self, ns: &Id, name: &str, kinds: &[&str]) -> Option<Id> {
        self.schema
            .objects
            .iter()
            .find(|o| &o.namespace == ns && o.name == name && kinds.contains(&o.kind.as_str()))
            .map(|o| o.id.clone())
    }

    /// Adds an object; refused when its namespace already has one of that name.
    fn object(
        &mut self,
        kind: &str,
        db: Option<&str>,
        name: &str,
        comment: Option<String>,
        section: ObjectSection,
    ) -> Result<Id, String> {
        let ns = self.namespace(db);
        if self.schema.objects.iter().any(|o| o.namespace == ns && o.name == name && same_space(kind, &o.kind)) {
            return Err(format!("`{name}` is already in the schema"));
        }
        let id = match self.freed.remove(&(ns.clone(), kind.to_string(), name.to_string())) {
            Some(id) => id,
            None => self.ids.next(Kind::Object, &[name]),
        };
        let mut o = Object::new(id.clone(), kind, ns, name);
        o.comment = comment;
        o.engine = sections::write(&canonical(section));
        self.schema.objects.push(o);
        Ok(id)
    }

    fn add_program(&mut self, kind: &str, p: program::Program) -> Result<Id, String> {
        let mut section = with!(ObjectSection { routine: Some(p.routine), options: p.options });
        self.with_settings(kind, &mut section.options);
        self.object(kind, p.db.as_deref(), &p.name, p.comment, section)
    }

    fn add_table(&mut self, t: table::Table) -> Result<Id, String> {
        let names: Vec<&str> = t.columns.iter().map(|c| c.name.as_str()).collect();
        let known = |n: &str| names.contains(&n);
        let parts =
            t.primary.iter().chain(&t.unique).flat_map(|k| &k.parts).chain(t.indexes.iter().flat_map(|i| &i.parts));
        for p in parts {
            if let Some(col) = &p.column
                && !known(col)
            {
                return Err(format!("a key names `{col}`, which is not a column of `{}`", t.name));
            }
        }
        for fk in &t.fks {
            if let Some(col) = fk.columns.iter().find(|c| !known(c)) {
                return Err(format!("a foreign key names `{col}`, which is not a column of `{}`", t.name));
            }
        }
        if let Some(p) = &t.partitioning {
            for b in &p.by {
                if let table::By::Column(col) = b
                    && !known(col)
                {
                    return Err(format!("the partitioning names `{col}`, which is not a column of `{}`", t.name));
                }
            }
        }
        let id = self.object(TABLE, t.db.as_deref(), &t.name, t.comment.clone(), ObjectSection::default())?;
        let mut columns = Vec::new();
        for col in t.columns {
            let cid = self.ids.next(Kind::Column, &[&t.name, &col.name]);
            let mut c = Column::new(cid, col.name, col.data_type, col.null);
            c.comment = col.comment;
            let mut cs = col.section;
            sort(&mut cs.options);
            c.engine = sections::write(&cs);
            columns.push(c);
        }
        let by_name: HashMap<String, Id> = columns.iter().map(|c| (c.name.clone(), c.id.clone())).collect();
        let col_id = |n: &str| by_name.get(n).cloned().ok_or_else(|| format!("`{n}` is not a column"));
        let mut s = with!(ObjectSection { options: t.options, checks: t.checks });
        let key = |k: table::KeyDef| to_key(k, &col_id);
        s.keys.primary = t.primary.map(key).transpose()?;
        s.keys.unique = t.unique.into_iter().map(key).collect::<Result<_, _>>()?;
        let mut taken: Vec<String> = s.keys.unique.iter().filter_map(|k| k.name.clone()).collect();
        taken.extend(t.indexes.iter().filter_map(|i| i.name.clone()));
        for i in t.indexes {
            s.indexes.push(index(i, &col_id, &mut taken)?);
        }
        if let Some(p) = t.partitioning {
            let mut part = Partitioning::default();
            part.strategy = Some(p.strategy);
            part.partitions = p.partitions;
            part.options = p.options;
            for b in p.by {
                let mut f = PartField::default();
                match b {
                    table::By::Column(n) => f.column = Some(col_id(&n)?),
                    table::By::Expression(e) => f.expression = Some(e),
                }
                part.by.push(f);
            }
            s.partitioning = Some(part);
        }
        for fk in t.fks {
            let cols = fk.columns.iter().map(|n| col_id(n)).collect::<Result<_, _>>()?;
            self.links.push(PendingLink { from: id.clone(), columns: cols, fk });
        }
        if let Some(o) = self.schema.objects.iter_mut().find(|o| o.id == id) {
            o.columns = columns;
            o.engine = sections::write(&canonical(s));
        }
        Ok(id)
    }

    /// `CREATE INDEX … ON table`: the index joins its table.
    fn add_index(&mut self, table: &(Option<String>, String), i: table::IndexDef) -> Result<Id, String> {
        let ns = match &table.0 {
            Some(db) => self.schema.namespaces.iter().find(|n| &n.name == db).map(|n| n.id.clone()),
            None => self.current.clone(),
        };
        let id = ns
            .and_then(|ns| self.find(&ns, &table.1, &[TABLE]))
            .ok_or_else(|| format!("`{}` is not a table read before it", table.1))?;
        let o = self.schema.objects.iter_mut().find(|o| o.id == id).ok_or("the table is gone")?;
        let by_name: HashMap<String, Id> = o.columns.iter().map(|c| (c.name.clone(), c.id.clone())).collect();
        let col_id = |n: &str| by_name.get(n).cloned().ok_or_else(|| format!("`{n}` is not a column of `{}`", table.1));
        let mut s: ObjectSection = sections::read(&o.engine)?;
        let mut taken: Vec<String> = s.indexes.iter().map(|i| i.name.clone()).collect();
        taken.extend(s.keys.unique.iter().filter_map(|k| k.name.clone()));
        match table::unique(i) {
            table::Unique::Key(k) => s.keys.unique.push(to_key(k, &col_id)?),
            table::Unique::Index(i) => s.indexes.push(index(i, &col_id, &mut taken)?),
        }
        o.engine = sections::write(&canonical(s));
        Ok(id)
    }

    fn finish(mut self) -> Result<Imported, String> {
        if self.no_backslash_escapes {
            return Err("statements here are made under NO_BACKSLASH_ESCAPES, so their strings would be misread: \
                        dump them without that SQL mode"
                .to_string());
        }
        let inline_enforced = versions::has(&self.version, &versions::INLINE_REFERENCES);
        for p in std::mem::take(&mut self.links) {
            self.link(p, inline_enforced);
        }
        self.view_reads();
        let mut section = SchemaSection::default();
        section.kept = std::mem::take(&mut self.kept);
        self.schema.engine_section = sections::write(&section);
        Ok(Imported::new(self.schema, self.report))
    }

    fn link(&mut self, p: PendingLink, inline_enforced: bool) {
        let Some(from) = self.schema.object(&p.from).cloned() else { return };
        let ns = match &p.fk.parent_db {
            Some(db) => self.schema.namespaces.iter().find(|n| &n.name == db).map(|n| n.id.clone()),
            None => Some(from.namespace.clone()),
        };
        let parent =
            ns.and_then(|ns| self.find(&ns, &p.fk.parent, &[TABLE])).and_then(|id| self.schema.object(&id).cloned());
        let to = parent.and_then(|o| {
            let cols: Option<Vec<Id>> =
                p.fk.parent_columns.iter().map(|n| o.column_named(n).map(|c| c.id.clone())).collect();
            cols.map(|c| (o.id.clone(), c))
        });
        match to {
            Some((parent, cols)) if !cols.is_empty() => {
                let base = p.fk.name.clone().unwrap_or_else(|| format!("{}_{}", from.name, p.fk.parent));
                let id = self.ids.next(Kind::Link, &[&base]);
                let mut l = Link::new(id, Ends::new(p.from, p.columns), Ends::new(parent, cols));
                l.name = p.fk.name;
                let mut section: LinkSection = p.fk.section;
                if section.options.contains_key("inline") && !inline_enforced {
                    section.enforced = false;
                }
                l.engine = sections::write(&section);
                self.schema.links.push(l);
            }
            _ => {
                if let Some(o) = self.schema.objects.iter_mut().find(|o| o.id == p.from)
                    && let Ok(mut s) = sections::read::<ObjectSection>(&o.engine)
                {
                    let list = s.options.entry("outside_references").or_insert_with(|| json!([]));
                    if let Value::Array(a) = list {
                        a.push(json!(p.fk.text));
                    }
                    o.engine = sections::write(&canonical(s));
                }
            }
        }
    }

    /// What each view reads, from its query.
    fn view_reads(&mut self) {
        let views: Vec<(Id, Id, String)> = self
            .schema
            .objects
            .iter()
            .filter(|o| o.kind == VIEW)
            .filter_map(|o| {
                let s: ObjectSection = sections::read(&o.engine).ok()?;
                Some((o.id.clone(), o.namespace.clone(), s.query?))
            })
            .collect();
        for (id, ns, query) in views {
            let Ok(names) = crate::queries::reads(&query) else { continue };
            let mut reads = Vec::new();
            for parts in names {
                let (db, name) = match parts.as_slice() {
                    [name] => (Some(ns.clone()), name),
                    [db, name] => (self.schema.namespaces.iter().find(|n| &n.name == db).map(|n| n.id.clone()), name),
                    _ => continue,
                };
                if let Some(r) = db.and_then(|db| self.find(&db, name, &[TABLE, VIEW]))
                    && r != id
                    && !reads.contains(&r)
                {
                    reads.push(r);
                }
            }
            if let Some(o) = self.schema.objects.iter_mut().find(|o| o.id == id) {
                o.reads = reads;
            }
        }
    }
}

/// A statement that may hold a credential, kept of `kind` without it; one whose credential cannot be cut out is not
/// kept at all, and counted with the data.
fn credentials(text: &str, kind: &'static str, lock: bool) -> Done {
    match server::without_credentials(text, lock) {
        Ok(cut) => Done::Cut(kind, cut),
        Err(_) => Done::Data,
    }
}

/// A section with every map of options in the order of its keys, so a schema is stored the same however its SQL
/// ordered the clauses.
fn canonical(mut s: ObjectSection) -> ObjectSection {
    sort(&mut s.options);
    for k in s.keys.primary.iter_mut().chain(&mut s.keys.unique) {
        sort(&mut k.options);
    }
    for i in &mut s.indexes {
        sort(&mut i.options);
        i.parts.iter_mut().for_each(|p| sort(&mut p.options));
    }
    s.checks.iter_mut().for_each(|c| sort(&mut c.options));
    if let Some(p) = &mut s.partitioning {
        sort(&mut p.options);
        p.partitions.iter_mut().for_each(|x| sort(&mut x.options));
    }
    if let Some(r) = &mut s.routine {
        sort(&mut r.options);
    }
    s
}

fn sort(o: &mut Options) {
    let mut all: Vec<(String, Value)> = std::mem::take(o).into_iter().collect();
    all.sort_by(|a, b| a.0.cmp(&b.0));
    o.extend(all);
}

/// Whether objects of kinds `a` and `b` share their names: tables and views do, and each other kind keeps its own.
fn same_space(a: &str, b: &str) -> bool {
    let rel = |k: &str| k == TABLE || k == VIEW;
    a == b
        || (rel(a) && rel(b))
        || ([FUNCTION, LOADABLE_FUNCTION].contains(&a) && [FUNCTION, LOADABLE_FUNCTION].contains(&b))
}

/// A key, its columns as ids; a prefix length or a descending part kept in its `parts`.
fn to_key(k: table::KeyDef, col_id: &dyn Fn(&str) -> Result<Id, String>) -> Result<Key, String> {
    let mut out = Key::default();
    out.name = k.name;
    out.options = k.options;
    out.columns = k.parts.iter().filter_map(|p| p.column.as_deref()).map(col_id).collect::<Result<_, _>>()?;
    if k.parts.iter().any(|p| p.length.is_some() || p.desc) {
        let parts: Vec<Value> = k
            .parts
            .iter()
            .map(|p| match (p.length, p.desc) {
                (None, false) => Value::Null,
                (l, d) => {
                    let mut m = serde_json::Map::new();
                    if let Some(l) = l {
                        m.insert("length".into(), json!(l));
                    }
                    if d {
                        m.insert("desc".into(), json!(true));
                    }
                    Value::Object(m)
                }
            })
            .collect();
        out.options.insert("parts".into(), Value::Array(parts));
    }
    Ok(out)
}

/// An index, its columns as ids, named as MySQL names one written without a name.
fn index(
    i: table::IndexDef,
    col_id: &dyn Fn(&str) -> Result<Id, String>,
    taken: &mut Vec<String>,
) -> Result<sections::Index, String> {
    let mut out = sections::Index::default();
    out.unique = i.unique;
    out.method = i.method;
    out.options = i.options;
    for p in &i.parts {
        let mut part = IndexPart::default();
        if let Some(c) = &p.column {
            part.column = Some(col_id(c)?);
        }
        part.expression.clone_from(&p.expression);
        if p.desc {
            part.direction = Some(sections::Direction::Desc);
        }
        if let Some(l) = p.length {
            part.options.insert("length".into(), json!(l));
        }
        out.parts.push(part);
    }
    out.name = match i.name {
        Some(n) => n,
        None => {
            let base = i.parts.first().and_then(|p| p.column.clone()).unwrap_or_else(|| "functional_index".to_string());
            let mut name = base.clone();
            let mut n = 2;
            while taken.contains(&name) {
                name = format!("{base}_{n}");
                n += 1;
            }
            taken.push(name.clone());
            name
        }
    };
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::BUILT_IN;

    fn read84(sql: &str) -> Imported {
        read(BUILT_IN, sql.to_string(), "8.4").expect("it reads")
    }

    #[test]
    fn what_is_not_mysqls_is_refused_not_misread() {
        assert!(read(BUILT_IN, "-- MariaDB dump 10.19\nCREATE TABLE t (a int);".into(), "8.4").is_err());
        assert!(is_mariadb("-- MySQL dump 10.19  Distrib 10.11.6-MariaDB, for Linux (x86_64)\n"));
        let row = "-- MySQL dump 10.13\nCREATE TABLE `t` (`a` text);\nINSERT INTO t VALUES ('/*M! is just text');\n";
        assert!(!is_mariadb(row) && read(BUILT_IN, row.into(), "8.4").is_ok(), "what a row holds never counts");
        let stray = read84("DELIMITER ;;\nCREATE TRIGGER nowhere.x BEFORE INSERT ON t FOR EACH ROW SET NEW.a = 1;;\n");
        assert!(stray.schema.namespaces.is_empty(), "a trigger that is not read makes no database");
        assert!(
            read(BUILT_IN, "/*M!999999\\- enable the sandbox mode */\nCREATE TABLE t (a int);".into(), "8.4").is_err()
        );
        assert!(is_mariadb("-- MySQL dump 10.19\n-- Server version\t11.11.6-MariaDB-ubu2204\n"));
        assert!(!is_mariadb("-- MySQL dump 10.13\n-- Server version\t8.4.13\n"));
        let e = read(
            BUILT_IN,
            "SET sql_mode = 'NO_BACKSLASH_ESCAPES';\nCREATE TABLE t (a varchar(9) DEFAULT 'C:\\x');".into(),
            "8.4",
        );
        assert!(e.is_err_and(|e| e.contains("NO_BACKSLASH_ESCAPES")));
        let i = read84(
            "CREATE TABLE `t` (`a` int);\nINSERT INTO t VALUES (1), ('it''s; not the end');\nINSERT INTO t VALUES (2);\n",
        );
        assert_eq!((i.report.read, i.report.data, i.report.modelled), (3, 2, 1), "rows counted, never tokenised");
    }

    #[test]
    fn a_trigger_on_a_missing_table_is_kept_in_its_place_with_what_follows_it() {
        let i = read84(
            "CREATE TABLE `t` (`a` int);\nDELIMITER ;;\nCREATE TRIGGER x BEFORE INSERT ON nowhere FOR EACH ROW SET \
             NEW.a = 1;;\nDELIMITER ;\nGRANT SELECT ON *.* TO r;\n",
        );
        assert!(i.report.adds_up());
        assert_eq!(i.report.not_understood.len(), 1);
        let section: SchemaSection = sections::read(&i.schema.engine_section).expect("a section");
        let kept: Vec<(&str, Option<&str>)> =
            section.kept.iter().map(|k| (k.kind.as_str(), k.after.as_ref().map(Id::as_str))).collect();
        assert_eq!(kept, [("other", Some("o_t")), ("grant", Some("o_t"))], "in order, after a part that is there");
        let written = crate::write::schema(&i.schema).expect("it writes");
        let trigger = written.find("CREATE TRIGGER x").expect("the trigger is written back");
        assert!(written.find("GRANT SELECT").is_some_and(|g| g > trigger), "{written}");
    }

    #[test]
    fn a_unique_index_is_the_same_key_however_it_is_made() {
        let inline = read84("CREATE TABLE `t` (`n` varchar(50), UNIQUE KEY `u` (`n`(10)));\n");
        let later = read84("CREATE TABLE `t` (`n` varchar(50));\nCREATE UNIQUE INDEX u ON t (n(10));\n");
        assert_eq!(inline.schema.objects[0].engine, later.schema.objects[0].engine);
        let written = crate::write::schema(&later.schema).expect("it writes");
        assert_eq!(read84(&written).schema.objects, later.schema.objects, "and reads back as itself");
    }

    #[test]
    fn a_dropped_objects_id_passes_only_to_one_of_its_kind() {
        let i = read84(
            "CREATE TABLE `x` (`a` int);\nDROP TABLE x;\nDELIMITER ;;\nCREATE PROCEDURE x() BEGIN END;;\nDELIMITER ;\n\
             CREATE TABLE `x` (`b` int);\n",
        );
        let ids: Vec<(&str, &str)> = i.schema.objects.iter().map(|o| (o.kind.as_str(), o.id.as_str())).collect();
        assert_eq!(ids, [("procedure", "o_x_2"), ("table", "o_x")]);
    }

    #[test]
    fn a_server_version_falls_in_an_engine_version() {
        assert_eq!(version_for("8.0.46"), "8.0");
        assert_eq!(version_for("8.4.13-log"), "8.4");
        assert_eq!(version_for("8.2.0"), "8.4");
        assert_eq!(version_for("9.1.0"), "9.7");
        assert_eq!(version_for("26.10.0"), "26.10");
        assert_eq!(version_for("27.1.0"), "26.10");
        assert_eq!(version_of("-- MySQL 9.7 schema, written by Schema Forge\n"), "9.7");
        assert_eq!(version_of("-- MySQL dump 10.13\n-- Server version\t8.0.46\n"), "8.0");
        assert_eq!(version_of("CREATE TABLE t (a int);"), versions::DEFAULT);
    }
}
