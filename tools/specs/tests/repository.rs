//! The spec check on the repository itself: as merged, it gives no finding (step 13's item: it needs Docker).

use std::path::PathBuf;

#[test]
fn in_docker_the_repository_as_merged_gives_no_finding() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut findings = schema_forge_specs::check(&root);
    findings.extend(schema_forge_specs::load(&root));
    for f in &findings {
        eprintln!("{f}");
    }
    assert!(findings.is_empty(), "{} findings on the repository", findings.len());
}
