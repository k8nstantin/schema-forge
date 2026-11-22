//! The conformance kit: what every engine is checked against, in its own tests.
//!
//! ```ignore
//! use schema_forge_engine::kit::{self, QuerySample, Sample, Samples};
//!
//! #[test]
//! fn the_engine_conforms() {
//!     kit::assert_conforms(&MyEngine, &Samples {
//!         files: &[Sample { path: Path::new("tests/samples/shop.sql"), written_back: true }],
//!         queries: &[QuerySample { query: "select * from sales.orders", reads: &[&["sales", "orders"]] }],
//!     });
//! }
//! ```
//!
//! It checks the engine's identity and versions; every type (its example reads back as itself, exactly, in the
//! versions that have it, and is refused as not in the version by the others); and every sample: recognised, read
//! with a report that adds up, a sound schema of this engine at one of its versions, every column's type its own,
//! every object's definition written, and, for a sample that says so, written and read back to the same schema, and
//! written the same way twice. Every part the engine has needs samples that exercise it; a part it does not have is
//! not checked.

use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};

use schema_forge_model::{Ids, Kind};

use crate::{Engine, Imported, Input, Parsed, Read, TypeError, Write};

/// What an engine is checked on.
#[derive(Debug, Clone, Copy, Default)]
pub struct Samples<'a> {
    /// Files the engine reads.
    pub files: &'a [Sample<'a>],
    /// Queries in the engine's SQL, with what each reads.
    pub queries: &'a [QuerySample<'a>],
}

/// A file the engine reads.
#[derive(Debug, Clone, Copy)]
pub struct Sample<'a> {
    pub path: &'a Path,
    /// Whether what the engine writes from it reads back to the same schema. True for a file in the form the engine
    /// writes (its SQL); false for a form it only reads (table metadata, a live catalog's export).
    pub written_back: bool,
}

/// A query and the tables and views it reads, as name parts.
#[derive(Debug, Clone, Copy)]
pub struct QuerySample<'a> {
    pub query: &'a str,
    pub reads: &'a [&'a [&'a str]],
}

/// Everything in `engine` and its samples that does not conform; none when it all does.
#[must_use]
pub fn check(engine: &dyn Engine, samples: &Samples<'_>) -> Vec<String> {
    let mut out = Vec::new();
    identity(engine, &mut out);
    types(engine, &mut out);
    match (engine.read(), samples.files.is_empty()) {
        (Some(_), true) => out.push("it reads files, but no sample file is given".to_string()),
        (None, false) => out.push("sample files are given, but the engine reads nothing".to_string()),
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
        Err(TypeError::NotInVersion { family, .. }) if !has && family == t.name => {}
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

/// Reads `text` as the engine reads a file.
fn read_text(engine: &dyn Engine, read: &dyn Read, text: &str) -> Result<Imported, String> {
    static N: AtomicUsize = AtomicUsize::new(0);
    let file = std::env::temp_dir().join(format!(
        "schema-forge-kit-{}-{}-{}",
        engine.id(),
        std::process::id(),
        N.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::write(&file, text).map_err(|e| format!("{}: {e}", file.display()))?;
    let result = Input::open(&file).and_then(|i| {
        if read.recognises(&i) { read.read(&i) } else { Err("the engine does not recognise what it wrote".to_string()) }
    });
    let _ = std::fs::remove_file(&file);
    result
}
