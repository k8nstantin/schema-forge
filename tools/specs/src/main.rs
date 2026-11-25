//! The spec check as a command: `cargo run -q -p schema-forge-specs [repository root]`.

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let root =
        std::env::args().nth(1).map_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."), PathBuf::from);
    let mut findings = schema_forge_specs::check(&root);
    findings.extend(schema_forge_specs::load(&root));
    for finding in &findings {
        println!("{finding}");
    }
    println!("spec check: {} findings", findings.len());
    if findings.is_empty() { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
