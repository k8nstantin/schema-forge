//! `example`: a made-up engine, small enough to read in one go, that implements the interface the way a real one
//! does. Its files are lines:
//!
//! ```text
//! example 2
//! table sales orders
//! column id int not-null
//! column total decimal(10,2) null
//! anything else is kept as written
//! ```

use std::fmt::Write as _;

use schema_forge_engine::{
    Availability, Engine, Imported, Input, Parsed, Read, Report, TypeGroup, TypeSpec, Types, Version, Write,
};
use schema_forge_model::{Column, Id, Ids, Kind, Namespace, Object, Schema};

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
    /// The report leaves the kept lines out.
    ReportShort,
    /// The writer leaves the kept lines out.
    WriterLoses,
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

const CATALOG: &[TypeSpec] = &[
    TypeSpec {
        name: "int",
        group: "numbers",
        meaning: "A whole number",
        example: "int",
        available: Availability::ALWAYS,
    },
    TypeSpec {
        name: "decimal(P,S)",
        group: "numbers",
        meaning: "An exact number with P digits, S after the point",
        example: "decimal(10,2)",
        available: Availability::ALWAYS,
    },
    TypeSpec {
        name: "text",
        group: "text",
        meaning: "Text of any length",
        example: "text",
        available: Availability::ALWAYS,
    },
    TypeSpec {
        name: "wide",
        group: "text",
        meaning: "Wide text",
        example: "wide",
        available: Availability::since("2"),
    },
];

const TWICE: &[TypeSpec] = &[CATALOG[0], CATALOG[0], CATALOG[1], CATALOG[2], CATALOG[3]];

const NO_VERSION: &[TypeSpec] = &[
    CATALOG[0],
    CATALOG[1],
    CATALOG[2],
    TypeSpec {
        name: "wide",
        group: "text",
        meaning: "Wide text",
        example: "wide",
        available: Availability::since("9"),
    },
];

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
}

impl Types for Example {
    fn groups(&self) -> &[TypeGroup] {
        GROUPS
    }

    fn catalog(&self) -> &[TypeSpec] {
        match self.broken {
            Broken::TypeTwice => TWICE,
            Broken::SinceNoVersion => NO_VERSION,
            _ => CATALOG,
        }
    }

    fn parse(&self, text: &str, version: &str) -> Result<Parsed, String> {
        let t = text.trim().to_ascii_lowercase();
        let simple = |family: &'static str| Ok(Parsed { family, text: family.to_string() });
        match t.as_str() {
            "int" => simple("int"),
            "text" => simple("text"),
            "wide" if version == "2" || self.broken == Broken::VersionIgnored => simple("wide"),
            "wide" => Err("wide text came in version 2".to_string()),
            _ => {
                let inner = t
                    .strip_prefix("decimal(")
                    .and_then(|r| r.strip_suffix(')'))
                    .ok_or(format!("`{text}` is not a type"))?;
                let (p, s) = inner.split_once(',').ok_or(format!("`{text}` needs a precision and a scale"))?;
                let (p, s): (u32, u32) = (
                    p.trim().parse().map_err(|_| format!("`{text}`: the precision is a number"))?,
                    s.trim().parse().map_err(|_| format!("`{text}`: the scale is a number"))?,
                );
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
        let mut lines = text.lines().enumerate().filter(|(_, l)| !l.trim().is_empty());
        let (_, head) = lines.next().ok_or("an empty file")?;
        let version = head.strip_prefix("example ").ok_or("not an example file")?.trim();
        let mut s = Schema::new(self.id, version);
        let mut ids = Ids::default();
        let mut report = Report { unit: "lines", read: 1, modelled: 1, ..Report::default() };
        let mut kept = Vec::new();
        for (n, line) in lines {
            report.read += 1;
            let words: Vec<&str> = line.split_whitespace().collect();
            match words.as_slice() {
                ["table", ns, name] => {
                    let namespace = match s.namespaces.iter().find(|x| x.name == *ns) {
                        Some(x) => x.id.clone(),
                        None => {
                            let id = ids.next(Kind::Namespace, &[ns]);
                            s.namespaces.push(Namespace {
                                id: id.clone(),
                                name: (*ns).to_string(),
                                parent: None,
                                comment: None,
                                engine: Default::default(),
                            });
                            id
                        }
                    };
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
                    let data_type = self.parse(ty, version).map(|p| p.text).unwrap_or_else(|_| (*ty).to_string());
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
                    kept.push(serde_json::Value::String(line.to_string()));
                    if self.broken != Broken::ReportShort {
                        *report.kept.entry("other".to_string()).or_default() += 1;
                    }
                    report.not_understood.push((format!("line {}", n + 1), line.chars().take(40).collect()));
                }
            }
        }
        if !kept.is_empty() {
            s.engine_section.insert("kept".to_string(), serde_json::Value::Array(kept));
        }
        Ok(Imported { schema: s, report })
    }
}

impl Write for Example {
    fn definition(&self, schema: &Schema, id: &Id) -> Option<String> {
        let o = schema.object(id)?;
        let mut out = String::new();
        table(&mut out, schema, o);
        Some(out)
    }

    fn schema(&self, schema: &Schema) -> String {
        let mut out = format!("example {}\n", schema.engine.version);
        for o in &schema.objects {
            table(&mut out, schema, o);
        }
        if self.broken != Broken::WriterLoses
            && let Some(kept) = schema.engine_section.get("kept").and_then(serde_json::Value::as_array)
        {
            for line in kept.iter().filter_map(serde_json::Value::as_str) {
                let _ = writeln!(out, "{line}");
            }
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
