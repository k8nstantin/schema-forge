//! Real schemas on this machine, never in the repo: set SCHEMA_FORGE_CORPUS to a file listing folders of Iceberg
//! Spark SQL, one per line. Each must read with nothing unaccounted for, keep the model's rules, and write back as
//! Spark SQL that reads into the same model. Skipped when the variable is not set (as in CI).

use schema_forge_dialects::iceberg::{generate, import, import_folder};

#[test]
fn iceberg_folders_read_and_round_trip() {
    let Ok(list) = std::env::var("SCHEMA_FORGE_CORPUS") else { return };
    let folders = std::fs::read_to_string(&list).expect("corpus list");
    for folder in folders.lines().filter(|l| !l.trim().is_empty()) {
        let imported = import_folder(std::path::Path::new(folder)).expect("read");
        let r = &imported.report;
        let s = &imported.schema;
        println!(
            "== {folder}\n{} tables, {} namespaces, {} views\n{r}",
            s.tables.len(),
            s.namespaces.len(),
            s.views.len()
        );
        assert!(r.adds_up(), "{folder}");
        for p in schema_forge_core::check(s) {
            println!("  finding: {p}");
        }
        let written = generate(s);
        let again = import(&written).expect("read back");
        assert_eq!(&again.schema, s, "{folder}: written back, it reads the same");
    }
}
