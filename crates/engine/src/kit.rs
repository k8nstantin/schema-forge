//! The conformance kit: what every engine is checked against, in its own tests.
//!
//! ```ignore
//! #[test]
//! fn the_engine_conforms() {
//!     schema_forge_engine::kit::assert_conforms(&MyEngine, &[Path::new("tests/samples/shop.sql")]);
//! }
//! ```
//!
//! It checks the engine's identity and versions, every type (its example reads back as itself, in exactly the
//! versions that have it), and every sample: recognised, read with a report that adds up, a sound schema of this engine
//! at one of its versions, every column's type one of its own, and, when the engine writes, written and read back to
//! the same schema. A part the engine does not have is not checked.

use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::{Engine, Input, Parsed};

/// Everything in `engine` and its `samples` that does not conform; none when it all does.
#[must_use]
pub fn check(engine: &dyn Engine, samples: &[&Path]) -> Vec<String> {
    let mut out = Vec::new();
    identity(engine, &mut out);
    types(engine, &mut out);
    for sample in samples {
        sample_conforms(engine, sample, &mut out);
    }
    out
}

/// Fails the test with every finding when `engine` does not conform.
///
/// # Panics
/// When there is a finding.
pub fn assert_conforms(engine: &dyn Engine, samples: &[&Path]) {
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
    let is_version = |v: &str| versions.iter().any(|x| x.id == v);
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
        for end in [t.available.since, t.available.until].into_iter().flatten() {
            if !is_version(end) {
                out.push(format!("the type `{}` names the version `{end}`, which is not one of its versions", t.name));
            }
        }
        for v in versions {
            let has = t.available.in_version(v.id, versions);
            match types.parse(t.example, v.id) {
                Ok(p) if has => {
                    if p.family != t.name {
                        out.push(format!("`{}` reads as the type `{}`, not `{}`", t.example, p.family, t.name));
                    }
                    match types.parse(&p.text, v.id) {
                        Ok(again) if again == p => {}
                        Ok(again) => out.push(format!(
                            "`{}` is written `{}`, which reads back as `{}`",
                            t.example, p.text, again.text
                        )),
                        Err(e) => {
                            out.push(format!("`{}` is written `{}`, which does not read back: {e}", t.example, p.text))
                        }
                    }
                }
                Ok(_) => out.push(format!("`{}` reads in version `{}`, which does not have it", t.example, v.id)),
                Err(e) if has => out.push(format!("`{}` does not read in version `{}`: {e}", t.example, v.id)),
                Err(_) => {}
            }
        }
    }
}

fn sample_conforms(engine: &dyn Engine, sample: &Path, out: &mut Vec<String>) {
    let at = sample.display();
    let Some(read) = engine.read() else {
        out.push(format!("{at}: a sample is given, but the engine reads nothing"));
        return;
    };
    let input = match Input::open(sample) {
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
        written_back(engine, read, write, &imported, sample, out);
    }
}

/// Writes the schema read from `sample`, reads what was written, and compares.
fn written_back(
    engine: &dyn Engine,
    read: &dyn crate::Read,
    write: &dyn crate::Write,
    first: &crate::Imported,
    sample: &Path,
    out: &mut Vec<String>,
) {
    static N: AtomicUsize = AtomicUsize::new(0);
    let at = sample.display();
    let text = write.schema(&first.schema);
    let file = std::env::temp_dir().join(format!(
        "schema-forge-kit-{}-{}-{}",
        engine.id(),
        std::process::id(),
        N.fetch_add(1, Ordering::Relaxed)
    ));
    if let Err(e) = std::fs::write(&file, &text) {
        return out.push(format!("{}: {e}", file.display()));
    }
    let again = Input::open(&file).and_then(|i| {
        if read.recognises(&i) { read.read(&i) } else { Err("the engine does not recognise what it wrote".to_string()) }
    });
    let _ = std::fs::remove_file(&file);
    match again {
        Ok(again) if again.schema == first.schema => {}
        Ok(again) => {
            let (a, b) = (first.schema.to_json(), again.schema.to_json());
            let line =
                a.lines().zip(b.lines()).position(|(x, y)| x != y).unwrap_or(a.lines().count().min(b.lines().count()));
            out.push(format!(
                "{at}: written and read back, it differs from line {} of the schema: `{}` became `{}`",
                line + 1,
                a.lines().nth(line).unwrap_or("(the end)").trim(),
                b.lines().nth(line).unwrap_or("(the end)").trim()
            ));
        }
        Err(e) => out.push(format!("{at}: what the engine writes does not read back: {e}")),
    }
}
