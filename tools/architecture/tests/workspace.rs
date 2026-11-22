//! The design, checked on this workspace: a breach fails `cargo test`.

use std::path::{Path, PathBuf};

use schema_forge_architecture::{Role, check, files, workspace};

#[test]
fn the_workspace_keeps_the_design() {
    let root = std::fs::canonicalize(Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")).expect("the workspace");
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
    assert!(
        breaches.is_empty(),
        "the design in docs/engines.md is broken:\n{}",
        breaches.iter().map(|b| format!("  {b}")).collect::<Vec<_>>().join("\n")
    );
}
