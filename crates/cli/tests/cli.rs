//! The command line, end to end, on a fresh workspace.

use std::process::Command;

fn fixtures() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../dialects/tests/fixtures")
}

fn run(workspace: &std::path::Path, args: &[&str]) -> (bool, String, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_schema-forge"))
        .arg("--workspace")
        .arg(workspace)
        .args(args)
        .output()
        .expect("run");
    (out.status.success(), String::from_utf8_lossy(&out.stdout).into(), String::from_utf8_lossy(&out.stderr).into())
}

#[test]
fn import_list_export_and_read_back() {
    let dir = tempfile::tempdir().expect("dir");
    let ws = dir.path().join("ws");
    let pg = fixtures().join("postgres/schema.sql");
    let (ok, out, err) = run(&ws, &["import", pg.to_str().expect("path"), "--schema", "shop"]);
    assert!(ok, "{err}");
    assert!(out.contains("98 statements") && out.contains("read into schema `shop` (postgres)"), "{out}");

    let lake = fixtures().join("iceberg");
    let (ok, out, err) = run(&ws, &["import", lake.to_str().expect("path"), "--schema", "lake"]);
    assert!(ok, "{err}");
    assert!(out.contains("(iceberg)"), "{out}");

    let (ok, out, _) = run(&ws, &["schemas"]);
    assert!(ok);
    assert_eq!(out, "lake\ticeberg\nshop\tpostgres\n");

    for (schema, reader) in [("shop", "postgres"), ("lake", "iceberg")] {
        let file = dir.path().join(format!("{schema}.sql"));
        let (ok, _, err) = run(&ws, &["export", "--schema", schema, "--out", file.to_str().expect("path")]);
        assert!(ok, "{err}");
        let back = format!("{schema}-again");
        let (ok, out, err) = run(&ws, &["import", file.to_str().expect("path"), "--schema", &back, "--target", reader]);
        assert!(ok, "{err}");
        assert!(!out.contains("not understood"), "{out}");
        let (a, b) = (run(&ws, &["export", "--schema", schema]).1, run(&ws, &["export", "--schema", &back]).1);
        assert_eq!(a, b, "{schema}: exported, read back and exported again, the same SQL");
    }
}

#[test]
fn unknown_input_asks_for_its_type() {
    let dir = tempfile::tempdir().expect("dir");
    let file = dir.path().join("x.sql");
    std::fs::write(&file, "CREATE TABLE t (a int);").expect("write");
    let (ok, _, err) = run(&dir.path().join("ws"), &["import", file.to_str().expect("path"), "--schema", "x"]);
    assert!(!ok && err.contains("--target"), "{err}");
}
