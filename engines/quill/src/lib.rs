//! Quill: a made-up database, and its engine, small enough to read in one go. It implements the interface the way a
//! real engine does, and it is built to be unlike MySQL in every way shared code could wrongly assume: a namespace is a
//! `shelf`, its kinds are `record` and `hook`, a connection is an `endpoint` and a `key`, it reads `non-blank lines`.
//! Every app and canvas test runs on it beside MySQL, so shared code that names one engine's vocabulary fails there.
//! The conformance kit's own tests break it on purpose, one way each (`Broken`).
//!
//! Its files are lines; blank lines are spacing, not content:
//!
//! ```text
//! quill 2
//! table sales orders
//! column id int not-null
//! column total decimal(10,2) null
//! trigger sales orders_touch before insert on orders: set new.placed = now()
//! set mode fast
//! anything else is kept as written, and written back in its place
//! ```
//!
//! A `set` line is the file's own machinery: counted, and left out. Its live database is a Quill file on this machine,
//! reached at its `endpoint` with a `key`: reading it live reads that file, the shelves `which` names.
//!
//! Its queries are `select … from <shelf>.<name>`, with `join`s.

use std::fmt::Write as _;

use schema_forge_engine::kinds::{ObjectKind, Slot};
use schema_forge_engine::live::{Field, FieldKind, Live, Outcome, Profile, Secret, Step, StepKind};
use schema_forge_engine::options::{OptionKind, OptionSpec, Part};
use schema_forge_engine::portable::{ArrowType, Mapped, Portable};
use schema_forge_engine::sections::{self, Change, Kept, ObjectSection, SchemaSection, Timing, Trigger};
use schema_forge_engine::{
    Availability, Engine, Imported, Input, Noun, Parsed, Queries, Read, Report, TypeError, TypeGroup, TypeSpec, Types,
    Unread, Version, Write,
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
    /// `wide` in version 1 says it came in version 1.
    WrongSince,
    /// It writes nothing, though a sample is to be written back.
    NoWriter,
    /// The report does not say what it counts.
    NoUnit,
    /// It writes, but reads nothing.
    NoReader,
    /// It holds an option it does not declare.
    UndeclaredOption,
    /// It stores something in a slot the section layout does not have.
    OffLayout,
    /// Its exact Arrow mapping of `wide` comes back as `text`.
    ArrowAstray,
    /// It reads its tables as `sheet`, a kind it does not declare.
    UnknownKind,
    /// It puts a query in a table, a slot a table does not use.
    WrongSlot,
    /// It declares the option `fast` twice for the same kinds and versions.
    OptionTwice,
    /// It does not map its types to Arrow.
    NoArrow,
    /// It writes its sections in a storage format later than it says it reads.
    LaterFormat,
    /// Its trigger is on a table that is not in the schema.
    TriggerOnNothing,
    /// It leaves its machinery out of the report.
    MachineryUncounted,
    /// It declares the connection field `host` twice.
    FieldTwice,
    /// It declares two secret fields.
    TwoSecrets,
    /// Its `mode` field defaults to a word that is not one of its choices.
    DefaultNotAChoice,
    /// A connection field has no label.
    FieldUnlabelled,
    /// Its connection summary shows the key.
    SummaryLeaks,
    /// It has no word for a shelf.
    NoWords,
}

pub struct Quill {
    pub id: &'static str,
    pub broken: Broken,
}

impl Quill {
    pub const fn new() -> Self {
        Self { id: "quill", broken: Broken::Nothing }
    }

    pub const fn broken(broken: Broken) -> Self {
        Self { id: "quill", broken }
    }
}

impl Default for Quill {
    fn default() -> Self {
        Self::new()
    }
}

const VERSIONS: &[Version] = &[Version::new("1", "Quill 1"), Version::new("2", "Quill 2")];

const GROUPS: &[TypeGroup] = &[TypeGroup::new("numbers", "Numbers"), TypeGroup::new("text", "Text")];

const INT: TypeSpec = TypeSpec::new("int", "numbers", "A whole number", "int");
const DECIMAL: TypeSpec =
    TypeSpec::new("decimal(P,S)", "numbers", "An exact number with P digits, S after the point", "decimal(10,2)");
const TEXT: TypeSpec = TypeSpec::new("text", "text", "Text of any length", "text");
const WIDE: TypeSpec = TypeSpec::new("wide", "text", "Wide text", "wide").since("2");

/// Its kinds of object: a record, which holds keys (the perspectives draw it as a table), and a hook, which runs on a
/// record. Its files write them `table` and `trigger`; its kinds are its own words.
pub const RECORD: &str = "record";
pub const HOOK: &str = "hook";
const KINDS: &[ObjectKind] =
    &[ObjectKind::new(RECORD, "Record", &[Slot::Keys]), ObjectKind::new(HOOK, "Hook", &[Slot::Trigger])];

/// The same option declared twice, to prove the kit finds it.
const OPTIONS_TWICE: &[OptionSpec] = &[
    OptionSpec::new(Part::Object, "fast", OptionKind::Flag, "Kept in memory for speed").for_kinds(&[RECORD]).since("2"),
    OptionSpec::new(Part::Object, "fast", OptionKind::Text, "Kept in memory, again").since("2"),
];

/// A table may be marked `fast`, from version 2.
const OPTIONS: &[OptionSpec] = &[OptionSpec::new(Part::Object, "fast", OptionKind::Flag, "Kept in memory for speed")
    .for_kinds(&[RECORD])
    .since("2")];

/// What a connection to its live database needs.
const FIELDS: &[Field] = &[
    Field::new("endpoint", "Endpoint", FieldKind::Path, "The Quill file that is the database").required(),
    Field::new("key", "Key", FieldKind::Secret, "The key that opens it"),
    Field::new("mode", "Mode", FieldKind::OneOf(&["safe", "fast"]), "How to open it").default("safe"),
];
/// The key that opens every Quill database.
pub const KEY: &str = "open-quill";
const FIELD_TWICE: &[Field] = &[
    Field::new("endpoint", "Endpoint", FieldKind::Path, "The Quill file that is the database"),
    Field::new("endpoint", "Endpoint again", FieldKind::Path, "Another"),
];
const TWO_SECRETS: &[Field] = &[
    Field::new("key", "Key", FieldKind::Secret, "The key"),
    Field::new("token", "Token", FieldKind::Secret, "A token too"),
];
const DEFAULT_NOT_A_CHOICE: &[Field] =
    &[Field::new("mode", "Mode", FieldKind::OneOf(&["safe", "fast"]), "How to connect").default("reckless")];
const FIELD_UNLABELLED: &[Field] =
    &[Field::new("endpoint", "", FieldKind::Path, "The Quill file that is the database")];

const CATALOG: &[TypeSpec] = &[INT, DECIMAL, TEXT, WIDE];
const TWICE: &[TypeSpec] = &[INT, INT, DECIMAL, TEXT, WIDE];
const NO_VERSION: &[TypeSpec] = &[INT, DECIMAL, TEXT, WIDE.available(Availability::since("9"))];
const UNWRITTEN: &[TypeSpec] = &[
    INT,
    TypeSpec::new("decimal(P,S)", "numbers", "An exact number with P digits, S after the point", "DECIMAL( 10 , 2 )"),
    TEXT,
    WIDE,
];

impl Engine for Quill {
    fn id(&self) -> &'static str {
        self.id
    }

    fn name(&self) -> &'static str {
        "Quill"
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

    fn namespace_word(&self) -> Noun {
        if self.broken == Broken::NoWords { Noun::new("", "") } else { Noun::new("shelf", "shelves") }
    }

    fn kinds(&self) -> &[ObjectKind] {
        KINDS
    }

    fn options(&self) -> &[OptionSpec] {
        if self.broken == Broken::OptionTwice { OPTIONS_TWICE } else { OPTIONS }
    }

    fn format(&self) -> u32 {
        1
    }

    fn read(&self) -> Option<&dyn Read> {
        if self.broken == Broken::NoReader { None } else { Some(self) }
    }

    fn write(&self) -> Option<&dyn Write> {
        if self.broken == Broken::NoWriter { None } else { Some(self) }
    }

    fn queries(&self) -> Option<&dyn Queries> {
        Some(self)
    }

    fn portable(&self) -> Option<&dyn Portable> {
        if self.broken == Broken::NoArrow { None } else { Some(self) }
    }

    fn live(&self) -> Option<&dyn Live> {
        Some(self)
    }
}

impl Live for Quill {
    fn fields(&self) -> &[Field] {
        match self.broken {
            Broken::FieldTwice => FIELD_TWICE,
            Broken::TwoSecrets => TWO_SECRETS,
            Broken::DefaultNotAChoice => DEFAULT_NOT_A_CHOICE,
            Broken::FieldUnlabelled => FIELD_UNLABELLED,
            _ => FIELDS,
        }
    }

    /// `shop.quill · fast`: never the key.
    fn summary(&self, profile: &Profile) -> String {
        let endpoint = profile.get("endpoint", FIELDS).unwrap_or_default();
        let name = std::path::Path::new(endpoint).file_name().map_or(endpoint.into(), |n| n.to_string_lossy());
        let summary = format!("{name} · {}", profile.get("mode", FIELDS).unwrap_or_default());
        if self.broken == Broken::SummaryLeaks {
            let key = profile.values.get("key").map_or("", String::as_str);
            return format!("{summary} · {key}");
        }
        summary
    }

    /// The endpoint is reached when its file is there; it is secure in `safe` mode; the key signs in; the file's first
    /// line says its version; a Quill key only reads.
    fn test(&self, profile: &Profile, secret: Option<&Secret>) -> Vec<Step> {
        let mut steps = Vec::new();
        let outcome = (|| {
            let endpoint =
                profile.get("endpoint", FIELDS).ok_or((StepKind::Reach, "no endpoint is given".to_string()))?;
            let text = std::fs::read_to_string(endpoint).map_err(|e| (StepKind::Reach, format!("{endpoint}: {e}")))?;
            steps.push(Step::new(StepKind::Reach, Outcome::Passed, format!("{endpoint} is there")));
            steps.push(match profile.get("mode", FIELDS) {
                Some("fast") => Step::new(StepKind::Secure, Outcome::Warning, "fast mode: opened without the lock"),
                _ => Step::new(StepKind::Secure, Outcome::Passed, "safe mode: opened with the lock"),
            });
            if secret.map(Secret::expose) != Some(KEY) {
                return Err((StepKind::SignIn, "the key does not open it".to_string()));
            }
            steps.push(Step::new(StepKind::SignIn, Outcome::Passed, "the key opens it"));
            let version = text.lines().next().and_then(|l| l.strip_prefix("quill ")).map(str::trim);
            let version = version.filter(|v| VERSIONS.iter().any(|x| x.id == *v));
            let version =
                version.ok_or((StepKind::Version, "it is not a Quill database this engine knows".to_string()))?;
            steps.push(Step::new(StepKind::Version, Outcome::Passed, format!("Quill {version}")));
            steps.push(Step::new(StepKind::Rights, Outcome::Passed, "a key only reads"));
            Ok(())
        })();
        if let Err((at, said)) = outcome {
            steps.push(Step::new(at, Outcome::Failed, said));
            let order = [StepKind::Reach, StepKind::Secure, StepKind::SignIn, StepKind::Version, StepKind::Rights];
            let from = order.iter().position(|s| *s == at).map_or(order.len(), |i| i + 1);
            for s in &order[from..] {
                steps.push(Step::new(*s, Outcome::Skipped, "not tried: a step before it failed"));
            }
        }
        steps
    }

    /// Reads the endpoint's file as a file is read, keeping the shelves `which` names (all when empty).
    fn read(&self, profile: &Profile, secret: Option<&Secret>, which: &[String]) -> Result<Imported, String> {
        let endpoint = profile.get("endpoint", FIELDS).ok_or("no endpoint is given")?;
        if secret.map(Secret::expose) != Some(KEY) {
            return Err("the key does not open it".to_string());
        }
        let mut imported = Read::read(self, &Input::open(std::path::Path::new(endpoint))?)?;
        if !which.is_empty() {
            let s = &mut imported.schema;
            let unknown: Vec<&String> = which.iter().filter(|w| !s.namespaces.iter().any(|n| &n.name == *w)).collect();
            if !unknown.is_empty() {
                return Err(format!(
                    "there is no shelf {}",
                    unknown.iter().map(|w| format!("`{w}`")).collect::<Vec<_>>().join(", ")
                ));
            }
            let kept: Vec<Id> = s.namespaces.iter().filter(|n| which.contains(&n.name)).map(|n| n.id.clone()).collect();
            s.namespaces.retain(|n| kept.contains(&n.id));
            s.objects.retain(|o| kept.contains(&o.namespace));
            let objects: Vec<Id> = s.objects.iter().map(|o| o.id.clone()).collect();
            s.links.retain(|l| objects.contains(&l.from.object) && objects.contains(&l.to.object));
        }
        Ok(imported)
    }
}

impl Portable for Quill {
    fn arrow_type(&self, type_text: &str, version: &str) -> Result<Mapped<ArrowType>, TypeError> {
        let p = self.parse(type_text, version)?;
        Ok(match p.family {
            "int" => Mapped::exact(ArrowType::Int64),
            "text" => Mapped::exact(ArrowType::Utf8),
            "wide" => Mapped::exact(ArrowType::LargeUtf8),
            _ => {
                // decimal(P,S): Arrow holds up to 38 digits in Decimal128 and 76 in Decimal256.
                let inner = p.text.trim_start_matches("decimal(").trim_end_matches(')');
                let (pr, sc) = inner.split_once(',').unwrap_or((inner, "0"));
                let (pr, sc): (u8, i8) = (pr.parse().unwrap_or(u8::MAX), sc.parse().unwrap_or(i8::MAX));
                match pr {
                    1..=38 => Mapped::exact(ArrowType::Decimal128(pr, sc)),
                    39..=76 => Mapped::exact(ArrowType::Decimal256(pr, sc)),
                    _ => Mapped::lost(
                        ArrowType::Utf8,
                        format!("`{}` is wider than any Arrow decimal: kept as text", p.text),
                    ),
                }
            }
        })
    }

    fn engine_type(&self, arrow: &ArrowType, version: &str) -> Mapped<String> {
        match arrow {
            ArrowType::Int8 | ArrowType::Int16 | ArrowType::Int32 | ArrowType::Int64 => Mapped::exact("int".into()),
            ArrowType::Utf8 => Mapped::exact("text".into()),
            ArrowType::LargeUtf8 if version == "2" && self.broken != Broken::ArrowAstray => {
                Mapped::exact("wide".into())
            }
            ArrowType::LargeUtf8 => Mapped::exact("text".into()),
            ArrowType::Decimal128(p, s) | ArrowType::Decimal256(p, s) => Mapped::exact(format!("decimal({p},{s})")),
            other => Mapped::lost("text".into(), format!("{other} has no type here: kept as text")),
        }
    }
}

impl Types for Quill {
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
        let simple = |family: &'static str| Ok(Parsed::new(family, family));
        match t.as_str() {
            "int" => simple("int"),
            "text" => simple("text"),
            "wide" if version == "2" || self.broken == Broken::VersionIgnored => simple("wide"),
            "wide" if self.broken == Broken::VersionUnsaid => Err(TypeError::NotAType("`wide` is not a type".into())),
            "wide" if self.broken == Broken::WrongSince => Err(TypeError::not_in_version("wide", Some("1"))),
            "wide" => Err(TypeError::not_in_version("wide", Some("2"))),
            _ => {
                let bad = |why: &str| TypeError::NotAType(format!("`{text}` {why}"));
                let inner =
                    t.strip_prefix("decimal(").and_then(|r| r.strip_suffix(')')).ok_or_else(|| bad("is not a type"))?;
                let (p, s) = inner.split_once(',').ok_or_else(|| bad("needs a precision and a scale"))?;
                let p: u32 = p.trim().parse().map_err(|_| bad("has a precision that is not a number"))?;
                let s: u32 = s.trim().parse().map_err(|_| bad("has a scale that is not a number"))?;
                Ok(Parsed::new("decimal(P,S)", format!("decimal({p},{s})")))
            }
        }
    }
}

impl Read for Quill {
    fn reads(&self) -> &'static str {
        "Quill files"
    }

    fn recognises(&self, input: &Input) -> bool {
        !input.is_dir && input.head.starts_with("quill ")
    }

    fn read(&self, input: &Input) -> Result<Imported, String> {
        let text = std::fs::read_to_string(&input.path).map_err(|e| format!("{}: {e}", input.path.display()))?;
        // Blank lines are spacing between entries, not content: they are not read.
        let mut lines = text.lines().enumerate().filter(|(_, l)| !l.trim().is_empty());
        let (_, head) = lines.next().ok_or("an empty file")?;
        let version = head.strip_prefix("quill ").ok_or("not a Quill file")?.trim();
        let mut s = Schema::new(self.id, version);
        let mut ids = Ids::default();
        let mut report = Report::new(if self.broken == Broken::NoUnit { "" } else { "non-blank lines" });
        report.read = 1;
        report.modelled = 1;
        // Each kept line remembers the table or column line it came after, so it is written back in its place.
        let mut kept = Vec::new();
        for (n, line) in lines {
            report.read += 1;
            let words: Vec<&str> = line.split_whitespace().collect();
            match words.as_slice() {
                ["set", ..] => {
                    if self.broken != Broken::MachineryUncounted {
                        report.machinery += 1;
                    }
                }
                ["table", ns, name, rest @ ..] if rest.iter().all(|w| *w == "fast") => {
                    let namespace = namespace(&mut s, &mut ids, ns);
                    let kind = if self.broken == Broken::UnknownKind { "sheet" } else { RECORD };
                    let mut o = Object::new(ids.next(Kind::Object, &[name]), kind, namespace, *name);
                    if !rest.is_empty() {
                        let mut t = ObjectSection::default();
                        let key = if self.broken == Broken::UndeclaredOption { "quick" } else { "fast" };
                        t.options.insert(key.to_string(), true.into());
                        o.engine = sections::write(&t);
                    }
                    s.objects.push(o);
                    report.modelled += 1;
                }
                ["trigger", ns, name, "before", "insert", "on", table, ..] if line.contains(": ") => {
                    let body = line.split_once(": ").map_or("", |(_, b)| b);
                    let namespace = namespace(&mut s, &mut ids, ns);
                    let on = match s.objects.iter().find(|o| o.name == table.trim_end_matches(':')) {
                        Some(o) if self.broken != Broken::TriggerOnNothing => o.id.clone(),
                        _ => Id::try_from("o_nowhere").map_err(|e| e.to_string())?,
                    };
                    let mut o = Object::new(ids.next(Kind::Object, &[name]), HOOK, namespace, *name);
                    let mut t = ObjectSection::default();
                    t.trigger = Some(Trigger::new(Timing::Before, vec![Change::Insert], on, body));
                    o.engine = sections::write(&t);
                    s.objects.push(o);
                    report.modelled += 1;
                }
                ["column", name, ty, null @ ("null" | "not-null")] if !s.objects.is_empty() => {
                    let o = s.objects.last_mut().expect("a table");
                    let id: Id = ids.next(Kind::Column, &[&o.name, name]);
                    let data_type = self.parse(ty, version).map_or_else(|_| (*ty).to_string(), |p| p.text);
                    o.columns.push(Column::new(id, *name, data_type, *null == "null"));
                    report.modelled += 1;
                }
                _ => {
                    let mut k = Kept::default();
                    k.kind = "other".to_string();
                    k.text = line.to_string();
                    k.after = s.objects.last().map(|o| o.columns.last().map_or(&o.id, |c| &c.id).clone());
                    kept.push(k);
                    if self.broken != Broken::ReportShort {
                        *report.kept.entry("other".to_string()).or_default() += 1;
                    }
                    let start: String = line.chars().take(40).collect();
                    report.not_understood.push(Unread::new(format!("line {}", n + 1), start));
                }
            }
        }
        let mut section = SchemaSection::default();
        section.kept = kept;
        s.engine_section = sections::write(&section);
        if self.broken == Broken::OffLayout {
            s.engine_section.insert("storage".to_string(), "heap".into());
        }
        if self.broken == Broken::LaterFormat {
            s.engine_section.insert("format".to_string(), 2.into());
        }
        if self.broken == Broken::WrongSlot
            && let Some(o) = s.objects.first_mut()
        {
            let mut t: ObjectSection = sections::read(&o.engine)?;
            t.query = Some("select 1".to_string());
            o.engine = sections::write(&t);
        }
        Ok(Imported::new(s, report))
    }
}

fn namespace(s: &mut Schema, ids: &mut Ids, name: &str) -> Id {
    if let Some(n) = s.namespaces.iter().find(|n| n.name == name) {
        return n.id.clone();
    }
    let id = ids.next(Kind::Namespace, &[name]);
    s.namespaces.push(Namespace::new(id.clone(), name));
    id
}

impl Write for Quill {
    fn definition(&self, schema: &Schema, id: &Id) -> Result<Option<String>, String> {
        if self.broken == Broken::NoDefinitions {
            return Ok(None);
        }
        let Some(o) = schema.object(id) else { return Ok(None) };
        let mut out = String::new();
        table(&mut out, schema, o)?;
        Ok(Some(out))
    }

    fn schema(&self, schema: &Schema) -> Result<String, String> {
        // Never write with something dropped: a section this engine cannot read is an error, not an empty one.
        sections::layout_of(&schema.engine_section)?;
        let section: SchemaSection = sections::read(&schema.engine_section)?;
        let kept: Vec<(Option<&str>, &str)> = match self.broken {
            Broken::WriterLoses => Vec::new(),
            _ => section.kept.iter().map(|k| (k.after.as_ref().map(Id::as_str), k.text.as_str())).collect(),
        };
        let kept_after = |after: Option<&str>, out: &mut String| {
            for (_, line) in kept.iter().filter(|(a, _)| *a == after) {
                let _ = writeln!(out, "{line}");
            }
        };
        let mut out = format!("quill {}\n", schema.engine.version);
        if self.broken == Broken::KeptToEnd {
            for o in &schema.objects {
                table(&mut out, schema, o)?;
            }
            for (_, line) in &kept {
                let _ = writeln!(out, "{line}");
            }
            return Ok(out);
        }
        kept_after(None, &mut out);
        for o in &schema.objects {
            header(&mut out, schema, o)?;
            kept_after(Some(o.id.as_str()), &mut out);
            for c in &o.columns {
                column(&mut out, c);
                kept_after(Some(c.id.as_str()), &mut out);
            }
        }
        Ok(out)
    }
}

fn table(out: &mut String, schema: &Schema, o: &Object) -> Result<(), String> {
    header(out, schema, o)?;
    for c in &o.columns {
        column(out, c);
    }
    Ok(())
}

fn header(out: &mut String, schema: &Schema, o: &Object) -> Result<(), String> {
    let ns = schema.namespace(&o.namespace).map_or("", |n| n.name.as_str());
    let section: ObjectSection = sections::read(&o.engine).map_err(|e| format!("`{}`: {e}", o.name))?;
    if let Some(t) = &section.trigger {
        let table = schema.object(&t.table).map_or(t.table.as_str(), |x| x.name.as_str());
        let _ = writeln!(out, "trigger {ns} {} before insert on {table}: {}", o.name, t.body);
        return Ok(());
    }
    let fast = if section.options.is_empty() { "" } else { " fast" };
    let _ = writeln!(out, "table {ns} {}{fast}", o.name);
    Ok(())
}

fn column(out: &mut String, c: &Column) {
    let _ = writeln!(out, "column {} {} {}", c.name, c.data_type, if c.null { "null" } else { "not-null" });
}

impl Queries for Quill {
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
