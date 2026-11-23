//! The design, checked on this workspace: a breach fails `cargo test`.

use std::path::{Path, PathBuf};

use schema_forge_architecture::{
    DATABASES, Role, Vocabulary, api_fields, canvas_files, check, files, shared_code, workspace,
};

fn root() -> PathBuf {
    std::fs::canonicalize(Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")).expect("the workspace")
}

fn report(what: &str, breaches: &[schema_forge_architecture::Breach]) {
    assert!(
        breaches.is_empty(),
        "{what}:\n{}",
        breaches.iter().map(|b| format!("  {b}")).collect::<Vec<_>>().join("\n")
    );
}

#[test]
fn the_workspace_keeps_the_design() {
    let root = root();
    let crates = workspace(&root).expect("the workspace's metadata");
    assert!(
        crates.iter().any(|c| c.role == Some(Role::Tool) && c.name == "schema-forge-architecture"),
        "the check sees the workspace (it found {} crates)",
        crates.len()
    );
    let breaches = check(&crates, |c| {
        let within = |p: PathBuf| p.strip_prefix(&root).map(Path::to_path_buf).unwrap_or(p);
        files(&root.join(&c.dir)).into_iter().map(|(p, text)| (within(p), text)).collect()
    });
    report("the design in docs/engines.md is broken", &breaches);
}

/// Every engine's words, from what each declares: Quill's among them, built unlike MySQL's on purpose.
fn vocabulary(root: &Path) -> Vocabulary {
    let mut words = Vec::new();
    for e in schema_forge_engines::for_tests().all() {
        let id = e.id();
        if let Some(live) = e.live() {
            words.extend(live.fields().iter().map(|f| (f.key.to_string(), format!("{id} connection field"))));
        }
        words.extend(e.kinds().iter().map(|k| (k.id.to_string(), format!("{id} kind"))));
        words.extend(e.options().iter().map(|o| (o.key.to_string(), format!("{id} option"))));
    }
    words.sort();
    words.dedup_by(|a, b| a.0 == b.0);
    let types = std::fs::read_to_string(root.join("canvas/src/api/types.ts")).unwrap_or_default();
    Vocabulary { words, api_fields: api_fields(&types) }
}

#[test]
fn shared_code_names_no_database_and_no_engine_word() {
    let root = root();
    let crates = workspace(&root).expect("the workspace's metadata");
    let within = |p: PathBuf| p.strip_prefix(&root).map(Path::to_path_buf).unwrap_or(p);
    let mut shared: Vec<(PathBuf, String)> = crates
        .iter()
        .filter(|c| c.role == Some(Role::App))
        .flat_map(|c| files(&root.join(&c.dir)))
        .map(|(p, t)| (within(p), t))
        .collect();
    let canvas = canvas_files(&root.join("canvas"));
    assert!(
        !root.join("canvas/package.json").exists() || !canvas.is_empty(),
        "the canvas is there but the check reads none of it"
    );
    shared.extend(canvas.into_iter().map(|(p, t)| (within(p), t)));
    let mut databases: Vec<String> = DATABASES.iter().map(|d| (*d).to_string()).collect();
    databases.extend(schema_forge_engines::for_tests().all().map(|e| e.id().to_string()));
    let vocabulary = vocabulary(&root);
    assert!(vocabulary.words.len() > 20, "the engines declare their words: {:?}", vocabulary.words);
    report("shared code names what belongs to an engine (docs/api.md)", &shared_code(&shared, &databases, &vocabulary));
}
