//! Writing PostgreSQL: the model written out reads back into the same model; and, when Docker is at hand
//! (SCHEMA_FORGE_DOCKER=1), the written SQL loads into a real PostgreSQL whose pg_dump reads back the same again.

use std::collections::BTreeMap;

use schema_forge_core::Schema;
use schema_forge_dialects::postgres::{generate, import};

fn fixture(name: &str) -> String {
    std::fs::read_to_string(format!("{}/tests/fixtures/postgres/{name}", env!("CARGO_MANIFEST_DIR"))).expect("fixture")
}

/// Two models are the same when everything but the kept statements is equal, and the kept statements around each
/// object are the same, in the same order (their ids follow reading order, and do not matter).
fn assert_same(a: &Schema, b: &Schema) {
    let bare = |s: &Schema| Schema { kept: Vec::new(), ..s.clone() };
    assert_eq!(bare(a), bare(b));
    let around = |s: &Schema| {
        let mut m: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        for k in &s.kept {
            let anchor = k.after.as_ref().map(ToString::to_string).unwrap_or_default();
            // A series' statements are kept as one, under an id made from its parent.
            m.entry(anchor).or_default().push((format!("{:?}", k.kind), k.text.clone()));
        }
        m
    };
    assert_eq!(around(a), around(b));
}

#[test]
fn written_sql_reads_back_into_the_same_model() {
    for name in ["schema.sql", "full.sql"] {
        let a = import(&fixture(name)).expect("read").schema;
        let sql = generate(&a);
        let b = import(&sql).expect("read back");
        assert!(b.report.not_understood.is_empty(), "{name}: {}", b.report);
        assert_same(&a, &b.schema);
        assert_eq!(generate(&b.schema), sql, "{name}: writing is stable");
    }
}

/// Loads the written SQL into a fresh PostgreSQL 17, dumps it with pg_dump, and reads that dump back.
#[test]
fn written_sql_loads_into_postgres_and_dumps_back_the_same() {
    if std::env::var("SCHEMA_FORGE_DOCKER").is_err() {
        return;
    }
    let model = import(&fixture("schema.sql")).expect("read").schema;
    let sql = generate(&model);
    let name = "schema-forge-pg-round-trip";
    let docker = |args: &[&str]| std::process::Command::new("docker").args(args).output().expect("docker");
    let _ = docker(&["rm", "-f", name]);
    let up = docker(&[
        "run",
        "-d",
        "--name",
        name,
        "-e",
        "POSTGRES_PASSWORD=t",
        "-e",
        "POSTGRES_DB=shop",
        "postgres:17-alpine",
    ]);
    assert!(up.status.success(), "{}", String::from_utf8_lossy(&up.stderr));
    let ready = (0..60).any(|_| {
        std::thread::sleep(std::time::Duration::from_secs(1));
        docker(&["exec", name, "pg_isready", "-U", "postgres", "-d", "shop"]).status.success()
    });
    assert!(ready, "postgres started");
    std::thread::sleep(std::time::Duration::from_secs(2));
    let role = docker(&["exec", name, "psql", "-U", "postgres", "-d", "shop", "-c", "CREATE ROLE reporter"]);
    assert!(role.status.success(), "{}", String::from_utf8_lossy(&role.stderr));
    let mut load = std::process::Command::new("docker")
        .args(["exec", "-i", name, "psql", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "shop"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("psql");
    use std::io::Write;
    load.stdin.take().expect("stdin").write_all(sql.as_bytes()).expect("write");
    let loaded = load.wait_with_output().expect("load");
    let dump = docker(&["exec", name, "pg_dump", "-U", "postgres", "--schema-only", "shop"]);
    let _ = docker(&["rm", "-f", name]);
    assert!(loaded.status.success(), "the written SQL loads: {}", String::from_utf8_lossy(&loaded.stderr));
    let back = import(&String::from_utf8_lossy(&dump.stdout)).expect("read the new dump");
    let without_kept = |s: &Schema| Schema { kept: Vec::new(), ..s.clone() };
    assert_eq!(without_kept(&back.schema), without_kept(&model), "pg_dump of the loaded schema reads the same");
}
