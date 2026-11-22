//! The conformance kit: what every engine is checked against, in its own tests.
//!
//! ```ignore
//! use schema_forge_engine::kit::{self, QuerySample, Sample, Samples};
//!
//! #[test]
//! fn the_engine_conforms() {
//!     let files = [Sample::written_back(Path::new("tests/samples/shop.sql"))];
//!     let queries = [QuerySample::new("select * from sales.orders", &[&["sales", "orders"]])];
//!     kit::assert_conforms(&MyEngine, &Samples::new(&files, &queries));
//! }
//! ```
//!
//! It checks the engine's identity and versions; every type (its example reads back as itself, exactly, in the
//! versions that have it, and is refused as not in the version by the others); and every sample: recognised, read
//! with a report that adds up, a sound schema of this engine at one of its versions, every section in the section
//! layout and every id a section names in the schema, every column's type its own,
//! every object's definition written, and, for a sample in the form the engine writes, written back as the same text
//! (blank lines aside) and read back to the same schema. Every part the engine has needs samples that exercise it; a
//! part it does not have is not checked.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use schema_forge_model::{Ids, Kind};

use crate::{Engine, Imported, Input, Parsed, Read, TypeError, Write};

/// What an engine is checked on.
#[derive(Debug, Clone, Copy, Default)]
#[non_exhaustive]
pub struct Samples<'a> {
    /// Files the engine reads.
    pub files: &'a [Sample<'a>],
    /// Queries in the engine's SQL, with what each reads.
    pub queries: &'a [QuerySample<'a>],
}

impl<'a> Samples<'a> {
    #[must_use]
    pub const fn new(files: &'a [Sample<'a>], queries: &'a [QuerySample<'a>]) -> Self {
        Self { files, queries }
    }
}

/// A file the engine reads.
#[derive(Debug, Clone, Copy)]
#[non_exhaustive]
pub struct Sample<'a> {
    pub path: &'a Path,
    /// Whether it is in the form the engine writes, exactly: read and written again, it must come back as the same
    /// text (blank lines aside) and read back to the same schema.
    pub written_back: bool,
}

impl<'a> Sample<'a> {
    /// A file in the form the engine writes (its SQL, as it writes it).
    #[must_use]
    pub const fn written_back(path: &'a Path) -> Self {
        Self { path, written_back: true }
    }

    /// A file in a form the engine only reads (table metadata, a dump made by another tool).
    #[must_use]
    pub const fn read_only(path: &'a Path) -> Self {
        Self { path, written_back: false }
    }
}

/// A query and the tables and views it reads, as name parts.
#[derive(Debug, Clone, Copy)]
#[non_exhaustive]
pub struct QuerySample<'a> {
    pub query: &'a str,
    pub reads: &'a [&'a [&'a str]],
}

impl<'a> QuerySample<'a> {
    #[must_use]
    pub const fn new(query: &'a str, reads: &'a [&'a [&'a str]]) -> Self {
        Self { query, reads }
    }
}

/// Everything in `engine` and its samples that does not conform; none when it all does.
#[must_use]
pub fn check(engine: &dyn Engine, samples: &Samples<'_>) -> Vec<String> {
    let mut out = Vec::new();
    identity(engine, &mut out);
    types(engine, &mut out);
    portable(engine, &mut out);
    match (engine.read(), samples.files.is_empty()) {
        (Some(_), true) => out.push("it reads files, but no sample file is given".to_string()),
        (None, false) => out.push("sample files are given, but the engine reads nothing".to_string()),
        _ => {}
    }
    let written_back = samples.files.iter().any(|f| f.written_back);
    match (engine.write(), written_back) {
        // A writer is checked by writing back what was read; an engine that writes and does not read is checked on
        // its types and identity only, until a part of the interface gives it schemas to write.
        (Some(_), false) if engine.read().is_some() => {
            out.push("it writes, but no sample is in the form it writes (`Sample::written_back`)".to_string());
        }
        (None, true) => out.push("a sample is to be written back, but the engine writes nothing".to_string()),
        _ => {}
    }
    if let Some(read) = engine.read() {
        for sample in samples.files {
            sample_conforms(engine, read, sample, &mut out);
        }
    }
    match engine.queries() {
        Some(_) if samples.queries.is_empty() => {
            out.push("it reads queries, but no sample query is given".to_string());
        }
        None if !samples.queries.is_empty() => {
            out.push("sample queries are given, but the engine reads no queries".to_string());
        }
        Some(queries) => {
            for q in samples.queries {
                let want: Vec<Vec<String>> =
                    q.reads.iter().map(|r| r.iter().map(|p| (*p).to_string()).collect()).collect();
                match queries.reads(q.query) {
                    Ok(got) if got == want => {}
                    Ok(got) => out.push(format!("`{}` reads {got:?}, not {want:?}", q.query)),
                    Err(e) => out.push(format!("`{}` does not read: {e}", q.query)),
                }
            }
        }
        None => {}
    }
    out
}

/// Fails the test with every finding when `engine` does not conform.
///
/// # Panics
/// When there is a finding.
pub fn assert_conforms(engine: &dyn Engine, samples: &Samples<'_>) {
    let findings = check(engine, samples);
    assert!(
        findings.is_empty(),
        "the engine `{}` does not conform:\n{}",
        engine.id(),
        findings.iter().map(|f| format!("  {f}")).collect::<Vec<_>>().join("\n")
    );
}

fn identity(engine: &dyn Engine, out: &mut Vec<String>) {
    let mut seen_options = HashSet::new();
    for o in engine.options() {
        if !seen_options.insert((o.part, o.key, o.kinds)) {
            out.push(format!("the option `{}` on {:?} is declared twice", o.key, o.part));
        }
        if o.meaning.trim().is_empty() {
            out.push(format!("the option `{}` says nothing about what it means", o.key));
        }
        for end in [o.available.since, o.available.until].into_iter().flatten() {
            if !engine.versions().iter().any(|v| v.id == end) {
                out.push(format!("the option `{}` names the version `{end}`, which is not one of its versions", o.key));
            }
        }
    }
    let id = engine.id();
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') {
        out.push(format!("its id `{id}` is not lowercase letters, digits and `_`"));
    }
    if engine.name().trim().is_empty() {
        out.push("it has no name".to_string());
    }
    let versions = engine.versions();
    if versions.is_empty() {
        out.push("it has no versions".to_string());
    }
    let mut seen = HashSet::new();
    for v in versions {
        if v.id.trim().is_empty() || v.name.trim().is_empty() {
            out.push(format!("a version without an id or a name (`{}`, `{}`)", v.id, v.name));
        }
        if !seen.insert(v.id) {
            out.push(format!("the version `{}` is listed twice", v.id));
        }
    }
    if !versions.iter().any(|v| v.id == engine.default_version()) {
        out.push(format!("its default version `{}` is not one of its versions", engine.default_version()));
    }
}

fn types(engine: &dyn Engine, out: &mut Vec<String>) {
    let versions = engine.versions();
    let at = |v: &str| versions.iter().position(|x| x.id == v);
    let types = engine.types();
    let mut groups = HashSet::new();
    for g in types.groups() {
        if !groups.insert(g.id) {
            out.push(format!("the type group `{}` is listed twice", g.id));
        }
    }
    if types.catalog().is_empty() {
        out.push("it has no types".to_string());
    }
    let mut names = HashSet::new();
    for t in types.catalog() {
        if !names.insert(t.name) {
            out.push(format!("the type `{}` is listed twice", t.name));
        }
        if !groups.contains(t.group) {
            out.push(format!("the type `{}` is in the group `{}`, which is not one of its groups", t.name, t.group));
        }
        if t.meaning.trim().is_empty() {
            out.push(format!("the type `{}` says nothing about what it holds", t.name));
        }
        let (since, until) = (t.available.since, t.available.until);
        for end in [since, until].into_iter().flatten() {
            if at(end).is_none() {
                out.push(format!("the type `{}` names the version `{end}`, which is not one of its versions", t.name));
            }
        }
        if let (Some(s), Some(u)) = (since.and_then(at), until.and_then(at))
            && s >= u
        {
            out.push(format!("the type `{}` is in no version: it goes before it comes", t.name));
        }
        for v in versions {
            example_reads(engine, t, v.id, out);
        }
    }
}

/// The type's example in version `version`: read back exactly where the version has it, refused as not in the
/// version where it does not.
fn example_reads(engine: &dyn Engine, t: &crate::TypeSpec, version: &str, out: &mut Vec<String>) {
    let has = t.available.in_version(version, engine.versions());
    let types = engine.types();
    match types.parse(t.example, version) {
        Ok(p) if has => {
            if p.family != t.name {
                out.push(format!("`{}` reads as the type `{}`, not `{}`", t.example, p.family, t.name));
            }
            if p.text != t.example {
                out.push(format!(
                    "the example `{}` of `{}` is written `{}`: an example is written as the engine writes it",
                    t.example, t.name, p.text
                ));
            }
            if types.parse(&p.text, version).as_ref() != Ok(&p) {
                out.push(format!("`{}` is written `{}`, which does not read back as itself", t.example, p.text));
            }
        }
        Ok(_) => out.push(format!("`{}` reads in version `{version}`, which does not have it", t.example)),
        Err(TypeError::NotInVersion { family, since }) if !has && family == t.name => {
            // Before the version it came in, say that version; once taken away, say none.
            let versions = engine.versions();
            let at = |v: &str| versions.iter().position(|x| x.id == v);
            // Not at or after the version it came in: before it, or that version is unknown (reported above).
            let before =
                t.available.since.is_some_and(|s| !matches!((at(version), at(s)), (Some(v), Some(s)) if v >= s));
            let want = if before { t.available.since } else { None };
            if since != want {
                out.push(format!(
                    "`{}` in version `{version}` says it came in {}, not {}",
                    t.example,
                    since.map_or("no version".to_string(), |v| format!("version {v}")),
                    want.map_or("no version (it was taken away)".to_string(), |v| format!("version {v}"))
                ));
            }
        }
        Err(e) if has => out.push(format!("`{}` does not read in version `{version}`: {e}", t.example)),
        Err(e) => out.push(format!(
            "`{}` in version `{version}`, which does not have it, should be refused as not in the version, not: {e}",
            t.example
        )),
    }
}

fn sample_conforms(engine: &dyn Engine, read: &dyn Read, sample: &Sample<'_>, out: &mut Vec<String>) {
    let at = sample.path.display();
    let input = match Input::open(sample.path) {
        Ok(i) => i,
        Err(e) => return out.push(e),
    };
    if !read.recognises(&input) {
        out.push(format!("{at}: the engine does not recognise its own sample"));
    }
    let imported = match read.read(&input) {
        Ok(i) => i,
        Err(e) => return out.push(format!("{at}: it does not read: {e}")),
    };
    let (schema, report) = (&imported.schema, &imported.report);
    if report.unit.trim().is_empty() {
        out.push(format!("{at}: the report does not say what it counts (its unit)"));
    }
    if report.not_understood.len() > report.kept_total() {
        out.push(format!(
            "{at}: the report lists {} things not understood, but kept only {}",
            report.not_understood.len(),
            report.kept_total()
        ));
    }
    if !report.adds_up() {
        out.push(format!(
            "{at}: the report does not add up: {} read, {} modelled, {} kept, {} data",
            report.read,
            report.modelled,
            report.kept_total(),
            report.data
        ));
    }
    if schema.engine.id != engine.id() {
        out.push(format!("{at}: it reads as a schema for `{}`", schema.engine.id));
    }
    let version = schema.engine.version.as_str();
    if !engine.versions().iter().any(|v| v.id == version) {
        out.push(format!("{at}: it reads at the version `{version}`, which is not one of the engine's"));
    }
    for p in schema_forge_model::check(schema) {
        out.push(format!("{at}: the model: {p}"));
    }
    for f in layout(schema) {
        out.push(format!("{at}: {f}"));
    }
    for f in declared(engine, schema) {
        out.push(format!("{at}: {f}"));
    }
    if let Some(checks) = engine.checks() {
        for p in checks.check(schema) {
            out.push(format!("{at}: the engine's checks: {p}"));
        }
    }
    for o in &schema.objects {
        for c in &o.columns {
            match engine.types().parse(&c.data_type, version) {
                Err(e) => out.push(format!(
                    "{at}: `{}.{}` has the type `{}`, which is not the engine's: {e}",
                    o.name, c.name, c.data_type
                )),
                Ok(Parsed { text, .. }) if text != c.data_type => out.push(format!(
                    "{at}: `{}.{}` has the type `{}`, which the engine writes `{text}`",
                    o.name, c.name, c.data_type
                )),
                Ok(_) => {}
            }
        }
    }
    if let Some(write) = engine.write() {
        for o in &schema.objects {
            if write.definition(schema, &o.id).is_none_or(|d| d.trim().is_empty()) {
                out.push(format!("{at}: `{}` has no definition", o.name));
            }
        }
        let nowhere = Ids::of(schema).next(Kind::Object, &["not", "in", "the", "schema"]);
        if write.definition(schema, &nowhere).is_some() {
            out.push(format!("{at}: an object that is not in the schema has a definition"));
        }
        if sample.written_back {
            written_back(engine, read, write, &imported, sample.path, out);
        }
    }
}

/// Writes the schema read from `sample`, reads what was written, and compares: the same schema, written the same way.
fn written_back(
    engine: &dyn Engine,
    read: &dyn Read,
    write: &dyn Write,
    first: &Imported,
    sample: &Path,
    out: &mut Vec<String>,
) {
    let at = sample.display();
    let text = write.schema(&first.schema);
    match std::fs::read_to_string(sample) {
        Ok(original) => {
            let lines = |t: &str| {
                t.lines().map(str::trim_end).filter(|l| !l.is_empty()).map(str::to_string).collect::<Vec<_>>()
            };
            let (a, b) = (lines(&original), lines(&text));
            if a != b {
                let n = a.iter().zip(&b).position(|(x, y)| x != y).unwrap_or(a.len().min(b.len()));
                out.push(format!(
                    "{at}: written back, it is not the sample: its line `{}` is written `{}`",
                    a.get(n).map_or("(the end)", String::as_str),
                    b.get(n).map_or("(the end)", String::as_str)
                ));
            }
        }
        Err(_) if sample.is_dir() => out.push(format!("{at}: a folder cannot be written back; mark it `read_only`")),
        Err(e) => out.push(format!("{at}: the sample cannot be read as text to compare: {e}")),
    }
    let again = match read_text(engine, read, &text) {
        Ok(a) => a,
        Err(e) => return out.push(format!("{at}: what the engine writes does not read back: {e}")),
    };
    if again.schema != first.schema {
        let (a, b) = (first.schema.to_json(), again.schema.to_json());
        let line =
            a.lines().zip(b.lines()).position(|(x, y)| x != y).unwrap_or(a.lines().count().min(b.lines().count()));
        out.push(format!(
            "{at}: written and read back, it differs from line {} of the schema: `{}` became `{}`",
            line + 1,
            a.lines().nth(line).unwrap_or("(the end)").trim(),
            b.lines().nth(line).unwrap_or("(the end)").trim()
        ));
    } else if write.schema(&again.schema) != text {
        out.push(format!("{at}: the same schema is written two different ways"));
    }
}

/// Reads `text` as the engine reads a file: written into a folder of its own, made new for it, and removed
/// afterwards, even when the engine panics.
fn read_text(engine: &dyn Engine, read: &dyn Read, text: &str) -> Result<Imported, String> {
    static N: AtomicUsize = AtomicUsize::new(0);

    /// Removes the folder when dropped, panic or not.
    struct Folder(PathBuf);
    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.subsec_nanos());
    let dir = std::env::temp_dir().join(format!(
        "schema-forge-kit-{}-{}-{}-{nanos}",
        engine.id(),
        std::process::id(),
        N.fetch_add(1, Ordering::Relaxed)
    ));
    // `create_dir` fails when the path is there already, whatever it is: nothing in place is followed or written.
    std::fs::create_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let folder = Folder(dir);
    let file = folder.0.join("written");
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&file)
        .map_err(|e| format!("{}: {e}", file.display()))?;
    std::io::Write::write_all(&mut f, text.as_bytes()).map_err(|e| format!("{}: {e}", file.display()))?;
    drop(f);
    let input = Input::open(&file)?;
    if read.recognises(&input) {
        read.read(&input)
    } else {
        Err("the engine does not recognise what it wrote".to_string())
    }
}

/// Whether every section of `schema` follows the section layout, and every id a section names is there.
fn layout(schema: &schema_forge_model::Schema) -> Vec<String> {
    use crate::sections::{
        ColumnSection, LinkSection, NamespaceSection, ObjectSection, SchemaSection, read as section,
    };
    let mut out = Vec::new();
    let mut bad = |part: &str, e: String| out.push(format!("the section of {part} does not follow the layout: {e}"));
    let ids: HashSet<&schema_forge_model::Id> = schema.ids().collect();
    match section::<SchemaSection>(&schema.engine_section) {
        Ok(s) => {
            for k in &s.kept {
                if let Some(after) = &k.after
                    && !ids.contains(after)
                {
                    bad("the schema", format!("a kept {} goes after {after}, which is not in the schema", k.kind));
                }
            }
        }
        Err(e) => bad("the schema", e),
    }
    for n in &schema.namespaces {
        if let Err(e) = section::<NamespaceSection>(&n.engine) {
            bad(&format!("namespace {}", n.id), e);
        }
    }
    for o in &schema.objects {
        let part = format!("`{}`", o.name);
        match section::<ObjectSection>(&o.engine) {
            Ok(t) => {
                for f in object_ids(schema, o, &t) {
                    bad(&part, f);
                }
            }
            Err(e) => bad(&part, e),
        }
        for c in &o.columns {
            if let Err(e) = section::<ColumnSection>(&c.engine) {
                bad(&format!("`{}.{}`", o.name, c.name), e);
            }
        }
    }
    for l in &schema.links {
        if let Err(e) = section::<LinkSection>(&l.engine) {
            bad(&format!("link {}", l.id), e);
        }
    }
    out
}

/// Every id an object's section names that is not where it should be.
fn object_ids(
    schema: &schema_forge_model::Schema,
    o: &schema_forge_model::Object,
    t: &crate::sections::ObjectSection,
) -> Vec<String> {
    let own: HashSet<&schema_forge_model::Id> = o.columns.iter().map(|c| &c.id).collect();
    let mut out = Vec::new();
    let mut mine = |what: &str, id: &schema_forge_model::Id| {
        if !own.contains(id) {
            out.push(format!("its {what} names {id}, which is not one of its columns"));
        }
    };
    for k in t.keys.primary.iter().chain(&t.keys.unique) {
        k.columns.iter().for_each(|c| mine("key", c));
    }
    t.keys.identifier.iter().for_each(|c| mine("identifier", c));
    for i in &t.indexes {
        i.parts.iter().filter_map(|p| p.column.as_ref()).for_each(|c| mine("index", c));
        i.include.iter().for_each(|c| mine("index", c));
    }
    if let Some(p) = &t.partitioning {
        p.by.iter().filter_map(|f| f.column.as_ref()).for_each(|c| mine("partitioning", c));
    }
    t.order.iter().for_each(|f| mine("order", &f.column));
    for i in &t.indexes {
        if i.parts.iter().any(|p| p.column.is_some() == p.expression.is_some()) {
            out.push(format!("a part of the index `{}` is not one column or one expression", i.name));
        }
    }
    if let Some(p) = &t.partition_of
        && schema.object(&p.parent).is_none()
    {
        out.push(format!("it is a partition of {}, which is not in the schema", p.parent));
    }
    if let Some(owner) = t.sequence.as_ref().and_then(|s| s.owned_by.as_ref())
        && schema.column(owner).is_none()
    {
        out.push(format!("it is owned by {owner}, which is not a column of the schema"));
    }
    out
}

/// Every option the sections of `schema` hold that `engine` does not declare for that part and kind, or whose value
/// is not of its kind, or that the schema's version does not have.
fn declared(engine: &dyn Engine, schema: &schema_forge_model::Schema) -> Vec<String> {
    use crate::options::Part;
    use crate::sections::{
        ColumnSection, LinkSection, NamespaceSection, ObjectSection, Options, SchemaSection, read as section,
    };
    let version = schema.engine.version.as_str();
    let mut out = Vec::new();
    let mut check = |part: Part, kind: Option<&str>, at: &str, options: &Options| {
        for (key, value) in options {
            let spec = engine.options().iter().find(|o| {
                o.part == part && o.key == key && (o.kinds.is_empty() || kind.is_some_and(|k| o.kinds.contains(&k)))
            });
            match spec {
                None => out.push(format!("{at} holds the option `{key}`, which the engine does not declare there")),
                Some(o) if !o.accepts(value) => {
                    out.push(format!("{at} holds `{key}` = {value}, which is not a {:?}", o.kind));
                }
                Some(o) if !o.available.in_version(version, engine.versions()) => {
                    out.push(format!("{at} holds `{key}`, which version {version} does not have"));
                }
                Some(_) => {}
            }
        }
    };
    if let Ok(s) = section::<SchemaSection>(&schema.engine_section) {
        check(Part::Schema, None, "the schema", &s.options);
    }
    for n in &schema.namespaces {
        if let Ok(s) = section::<NamespaceSection>(&n.engine) {
            check(Part::Namespace, None, &format!("namespace `{}`", n.name), &s.options);
        }
    }
    for o in &schema.objects {
        let kind = Some(o.kind.as_str());
        let at = format!("`{}`", o.name);
        if let Ok(t) = section::<ObjectSection>(&o.engine) {
            check(Part::Object, kind, &at, &t.options);
            for k in t.keys.primary.iter().chain(&t.keys.unique) {
                check(Part::Key, kind, &at, &k.options);
            }
            t.checks.iter().for_each(|c| check(Part::Check, kind, &at, &c.options));
            for i in &t.indexes {
                check(Part::Index, kind, &at, &i.options);
                i.parts.iter().for_each(|p| check(Part::IndexPart, kind, &at, &p.options));
            }
            if let Some(p) = &t.partitioning {
                check(Part::Partitioning, kind, &at, &p.options);
                p.by.iter().for_each(|f| check(Part::PartField, kind, &at, &f.options));
                p.partitions.iter().for_each(|x| check(Part::Partition, kind, &at, &x.options));
            }
            if let Some(q) = &t.sequence {
                check(Part::Sequence, kind, &at, &q.options);
            }
            if let Some(d) = &t.domain {
                check(Part::Domain, kind, &at, &d.options);
            }
            t.fields.iter().for_each(|f| check(Part::Field, kind, &at, &f.options));
        }
        for c in &o.columns {
            if let Ok(cs) = section::<ColumnSection>(&c.engine) {
                let at = format!("`{}.{}`", o.name, c.name);
                check(Part::Column, kind, &at, &cs.options);
                if let Some(i) = &cs.identity {
                    check(Part::Identity, kind, &at, &i.options);
                }
            }
        }
    }
    for l in &schema.links {
        if let Ok(s) = section::<LinkSection>(&l.engine) {
            check(Part::Link, None, &format!("link {}", l.id), &s.options);
        }
    }
    out
}

/// Every type's example maps to Arrow in every version that has it; an exact mapping comes back as the same type.
fn portable(engine: &dyn Engine, out: &mut Vec<String>) {
    use crate::portable::Fidelity;
    let Some(p) = engine.portable() else { return };
    for t in engine.types().catalog() {
        for v in engine.versions() {
            if !t.available.in_version(v.id, engine.versions()) {
                continue;
            }
            match p.arrow_type(t.example, v.id) {
                Ok(m) if m.fidelity == Fidelity::Exact => {
                    let back = p.engine_type(&m.to, v.id);
                    if back.to != t.example {
                        out.push(format!(
                            "`{}` maps to Arrow `{}` exactly, but comes back as `{}` in version `{}`",
                            t.example, m.to, back.to, v.id
                        ));
                    }
                }
                Ok(m) if m.lost.is_none() => out
                    .push(format!("`{}` maps to Arrow `{}` with something lost, without saying what", t.example, m.to)),
                Ok(_) => {}
                Err(e) => out.push(format!("`{}` does not map to Arrow in version `{}`: {e}", t.example, v.id)),
            }
        }
    }
}
