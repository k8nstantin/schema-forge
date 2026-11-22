//! `example`: a made-up engine, small enough to read in one go, that implements the interface the way a real one
//! does. Its files are lines; blank lines are spacing, not content:
//!
//! ```text
//! example 2
//! table sales orders
//! column id int not-null
//! column total decimal(10,2) null
//! anything else is kept as written, and written back in its place
//! ```
//!
//! Its queries are `select … from <namespace>.<name>`, with `join`s.

use std::fmt::Write as _;

use schema_forge_engine::{
    Availability, Engine, Imported, Input, Parsed, Queries, Read, Report, TypeError, TypeGroup, TypeSpec, Types,
    Unread, Version, Write,
};
use schema_forge_model::{Column, Id, Ids, Kind, Namespace, Object, Schema};
use serde_json::{Value, json};

/// What a broken copy of the engine gets wrong, to prove the kit finds it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Broken {
    Nothing,
    /// `int` listed twice.
    TypeTwice,
    /// `wide` says it came in version `9`.
    SinceNoVersion,
    /// `wide` reads in version 1, which does not have it.
    VersionIgnored,
    /// `wide` in version 1 is refused as not a type, instead of as not in the version.
    VersionUnsaid,
    /// The example of `decimal(P,S)` is not written as the engine writes it.
    ExampleUnwritten,
    /// The report leaves the kept lines out.
    ReportShort,
    /// The writer leaves the kept lines out.
    WriterLoses,
    /// The writer puts kept lines at the end, not in their place.
    KeptToEnd,
    /// No object has a definition.
    NoDefinitions,
    /// Queries read nothing.
    QueriesBlind,
    /// Its default version is not one of its versions.
    DefaultNoVersion,
}

pub struct Example {
    pub id: &'static str,
    pub broken: Broken,
}

impl Example {
    pub const fn new() -> Self {
        Self { id: "example", broken: Broken::Nothing }
    }

    pub const fn broken(broken: Broken) -> Self {
        Self { id: "example", broken }
    }
}

const VERSIONS: &[Version] = &[Version { id: "1", name: "example 1" }, Version { id: "2", name: "example 2" }];

const GROUPS: &[TypeGroup] = &[TypeGroup { id: "numbers", title: "Numbers" }, TypeGroup { id: "text", title: "Text" }];

const INT: TypeSpec = TypeSpec {
    name: "int",
    group: "numbers",
    meaning: "A whole number",
    example: "int",
    available: Availability::ALWAYS,
};
const DECIMAL: TypeSpec = TypeSpec {
    name: "decimal(P,S)",
    group: "numbers",
    meaning: "An exact number with P digits, S after the point",
    example: "decimal(10,2)",
    available: Availability::ALWAYS,
};
const TEXT: TypeSpec = TypeSpec {
    name: "text",
    group: "text",
    meaning: "Text of any length",
    example: "text",
    available: Availability::ALWAYS,
};
const WIDE: TypeSpec = TypeSpec {
    name: "wide",
    group: "text",
    meaning: "Wide text",
    example: "wide",
    available: Availability::since("2"),
};

const CATALOG: &[TypeSpec] = &[INT, DECIMAL, TEXT, WIDE];
const TWICE: &[TypeSpec] = &[INT, INT, DECIMAL, TEXT, WIDE];
const NO_VERSION: &[TypeSpec] = &[INT, DECIMAL, TEXT, TypeSpec { available: Availability::since("9"), ..WIDE }];
const UNWRITTEN: &[TypeSpec] = &[INT, TypeSpec { example: "DECIMAL( 10 , 2 )", ..DECIMAL }, TEXT, WIDE];

impl Engine for Example {
    fn id(&self) -> &'static str {
        self.id
    }

    fn name(&self) -> &'static str {
        "Example"
    }

    fn versions(&self) -> &[Version] {
        VERSIONS
    }

    fn default_version(&self) -> &'static str {
        if self.broken == Broken::DefaultNoVersion { "0" } else { "2" }
    }

    fn types(&self) -> &dyn Types {
        self
    }

    fn read(&self) -> Option<&dyn Read> {
        Some(self)
    }

    fn write(&self) -> Option<&dyn Write> {
        Some(self)
    }

    fn queries(&self) -> Option<&dyn Queries> {
        Some(self)
    }
}

impl Types for Example {
    fn groups(&self) -> &[TypeGroup] {
        GROUPS
    }

    fn catalog(&self) -> &[TypeSpec] {
        match self.broken {
            Broken::TypeTwice => TWICE,
            Broken::SinceNoVersion => NO_VERSION,
            Broken::ExampleUnwritten => UNWRITTEN,
            _ => CATALOG,
        }
    }

    fn parse(&self, text: &str, version: &str) -> Result<Parsed, TypeError> {
        let t = text.trim().to_ascii_lowercase();
        let simple = |family: &'static str| Ok(Parsed { family, text: family.to_string() });
        match t.as_str() {
            "int" => simple("int"),
            "text" => simple("text"),
            "wide" if version == "2" || self.broken == Broken::VersionIgnored => simple("wide"),
            "wide" if self.broken == Broken::VersionUnsaid => Err(TypeError::NotAType("`wide` is not a type".into())),
            "wide" => Err(TypeError::NotInVersion { family: "wide", since: Some("2") }),
            _ => {
                let bad = |why: &str| TypeError::NotAType(format!("`{text}` {why}"));
                let inner =
                    t.strip_prefix("decimal(").and_then(|r| r.strip_suffix(')')).ok_or_else(|| bad("is not a type"))?;
                let (p, s) = inner.split_once(',').ok_or_else(|| bad("needs a precision and a scale"))?;
                let p: u32 = p.trim().parse().map_err(|_| bad("has a precision that is not a number"))?;
                let s: u32 = s.trim().parse().map_err(|_| bad("has a scale that is not a number"))?;
                Ok(Parsed { family: "decimal(P,S)", text: format!("decimal({p},{s})") })
            }
        }
    }
}

impl Read for Example {
    fn reads(&self) -> &'static str {
        "example files"
    }

    fn recognises(&self, input: &Input) -> bool {
        !input.is_dir && input.head.starts_with("example ")
    }

    fn read(&self, input: &Input) -> Result<Imported, String> {
        let text = std::fs::read_to_string(&input.path).map_err(|e| format!("{}: {e}", input.path.display()))?;
        // Blank lines are spacing between entries, not content: they are not read.
        let mut lines = text.lines().enumerate().filter(|(_, l)| !l.trim().is_empty());
        let (_, head) = lines.next().ok_or("an empty file")?;
        let version = head.strip_prefix("example ").ok_or("not an example file")?.trim();
        let mut s = Schema::new(self.id, version);
        let mut ids = Ids::default();
        let mut report = Report { unit: "non-blank lines", read: 1, modelled: 1, ..Report::default() };
        // Each kept line remembers the object it came after, so it is written back in its place.
        let mut kept = Vec::new();
        for (n, line) in lines {
            report.read += 1;
            let words: Vec<&str> = line.split_whitespace().collect();
            match words.as_slice() {
                ["table", ns, name] => {
                    let namespace = namespace(&mut s, &mut ids, ns);
                    s.objects.push(Object {
                        id: ids.next(Kind::Object, &[name]),
                        kind: "table".to_string(),
                        namespace,
                        name: (*name).to_string(),
                        comment: None,
                        notes: None,
                        tags: Vec::new(),
                        area: None,
                        columns: Vec::new(),
                        reads: Vec::new(),
                        engine: Default::default(),
                    });
                    report.modelled += 1;
                }
                ["column", name, ty, null @ ("null" | "not-null")] if !s.objects.is_empty() => {
                    let o = s.objects.last_mut().expect("a table");
                    let id: Id = ids.next(Kind::Column, &[&o.name, name]);
                    let data_type = self.parse(ty, version).map_or_else(|_| (*ty).to_string(), |p| p.text);
                    o.columns.push(Column {
                        id,
                        name: (*name).to_string(),
                        data_type,
                        null: *null == "null",
                        comment: None,
                        engine: Default::default(),
                    });
                    report.modelled += 1;
                }
                _ => {
                    let after = s.objects.last().map_or(Value::Null, |o| Value::String(o.id.to_string()));
                    kept.push(json!({ "after": after, "line": line }));
                    if self.broken != Broken::ReportShort {
                        *report.kept.entry("other".to_string()).or_default() += 1;
                    }
                    report
                        .not_understood
                        .push(Unread { at: format!("line {}", n + 1), start: line.chars().take(40).collect() });
                }
            }
        }
        if !kept.is_empty() {
            s.engine_section.insert("kept".to_string(), Value::Array(kept));
        }
        Ok(Imported { schema: s, report })
    }
}

fn namespace(s: &mut Schema, ids: &mut Ids, name: &str) -> Id {
    if let Some(n) = s.namespaces.iter().find(|n| n.name == name) {
        return n.id.clone();
    }
    let id = ids.next(Kind::Namespace, &[name]);
    s.namespaces.push(Namespace {
        id: id.clone(),
        name: name.to_string(),
        parent: None,
        comment: None,
        engine: Default::default(),
    });
    id
}

impl Write for Example {
    fn definition(&self, schema: &Schema, id: &Id) -> Option<String> {
        if self.broken == Broken::NoDefinitions {
            return None;
        }
        let o = schema.object(id)?;
        let mut out = String::new();
        table(&mut out, schema, o);
        Some(out)
    }

    fn schema(&self, schema: &Schema) -> String {
        let kept: Vec<(Option<&str>, &str)> = match self.broken {
            Broken::WriterLoses => Vec::new(),
            _ => schema
                .engine_section
                .get("kept")
                .and_then(Value::as_array)
                .map(|k| k.iter().filter_map(|e| Some((e["after"].as_str(), e["line"].as_str()?))).collect())
                .unwrap_or_default(),
        };
        let kept_after = |after: Option<&str>, out: &mut String| {
            for (_, line) in kept.iter().filter(|(a, _)| *a == after) {
                let _ = writeln!(out, "{line}");
            }
        };
        let mut out = format!("example {}\n", schema.engine.version);
        if self.broken == Broken::KeptToEnd {
            for o in &schema.objects {
                table(&mut out, schema, o);
            }
            for (_, line) in &kept {
                let _ = writeln!(out, "{line}");
            }
            return out;
        }
        kept_after(None, &mut out);
        for o in &schema.objects {
            table(&mut out, schema, o);
            kept_after(Some(o.id.as_str()), &mut out);
        }
        out
    }
}

fn table(out: &mut String, schema: &Schema, o: &Object) {
    let ns = schema.namespace(&o.namespace).map_or("", |n| n.name.as_str());
    let _ = writeln!(out, "table {ns} {}", o.name);
    for c in &o.columns {
        let _ = writeln!(out, "column {} {} {}", c.name, c.data_type, if c.null { "null" } else { "not-null" });
    }
}

impl Queries for Example {
    fn reads(&self, query: &str) -> Result<Vec<Vec<String>>, String> {
        let words: Vec<&str> = query.split_whitespace().collect();
        if !words.first().is_some_and(|w| w.eq_ignore_ascii_case("select")) {
            return Err("a query starts with select".to_string());
        }
        if self.broken == Broken::QueriesBlind {
            return Ok(Vec::new());
        }
        let mut out: Vec<Vec<String>> = Vec::new();
        for pair in words.windows(2) {
            if pair[0].eq_ignore_ascii_case("from") || pair[0].eq_ignore_ascii_case("join") {
                let name: Vec<String> = pair[1].split('.').map(str::to_string).collect();
                if !out.contains(&name) {
                    out.push(name);
                }
            }
        }
        Ok(out)
    }
}
