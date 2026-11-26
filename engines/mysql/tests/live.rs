//! Reading a live MySQL, against a throwaway server of each version in Docker: the connection test's five steps, and a
//! live read that gives the same schema as the dump of the same database. Needs Docker and the `mysql:<version>`
//! images; run with `cargo test -p schema-forge-mysql --test live -- --ignored`.

use std::collections::BTreeMap;
use std::path::Path;
use std::process::{Command, Stdio};

use schema_forge_engine::live::{Outcome, Profile, Secret, StepKind};
use schema_forge_engine::sections::{ObjectSection, read, write};
use schema_forge_engine::{Engine, Input};
use schema_forge_model::Schema;
use schema_forge_mysql::Mysql;

const ROOT: &str = "samples";
const READER: &str = "samples-reader";

/// A throwaway MySQL in Docker, removed when dropped.
struct Server {
    name: String,
    port: String,
}

impl Server {
    fn start(version: &str) -> Self {
        Self::named(version, &format!("schema-forge-mysql-live-{}", version.replace('.', "-")))
    }

    fn named(version: &str, name: &str) -> Self {
        let name = name.to_string();
        let _ = Command::new("docker").args(["rm", "-f", "-v", &name]).output();
        let image = format!("mysql:{version}");
        let env = format!("MYSQL_ROOT_PASSWORD={ROOT}");
        let ok = Command::new("docker")
            .args(["run", "-d", "--name", &name, "-p", "127.0.0.1::3306", "-e", &env, &image])
            .stdout(Stdio::null())
            .status()
            .expect("docker runs");
        assert!(ok.success(), "{image} starts");
        let mut server = Self { port: String::new(), name };
        for _ in 0..90 {
            if server.sql("SELECT 1").is_ok() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
        let out = Command::new("docker").args(["port", &server.name, "3306"]).output().expect("docker port");
        let port = String::from_utf8_lossy(&out.stdout)
            .lines()
            .next()
            .and_then(|l| l.rsplit(':').next())
            .expect("a port")
            .trim()
            .to_string();
        server.port = port;
        server
    }

    /// Runs SQL as root through the server's own client, as the dumps were made.
    fn sql(&self, sql: &str) -> Result<(), String> {
        let mut child = Command::new("docker")
            .args(["exec", "-i", &self.name, "mysql", "-uroot", &format!("-p{ROOT}")])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| e.to_string())?;
        std::io::Write::write_all(child.stdin.as_mut().ok_or("stdin")?, sql.as_bytes()).map_err(|e| e.to_string())?;
        let out = child.wait_with_output().map_err(|e| e.to_string())?;
        let err = String::from_utf8_lossy(&out.stderr)
            .lines()
            .filter(|l| !l.contains("Using a password"))
            .collect::<Vec<_>>()
            .join("\n");
        if out.status.success() { Ok(()) } else { Err(err) }
    }

    /// The output of SQL run as root, tab-separated.
    fn query(&self, sql: &str) -> String {
        let out = Command::new("docker")
            .args(["exec", &self.name, "mysql", "-uroot", &format!("-p{ROOT}"), "-N", "-e", sql])
            .output()
            .expect("docker exec");
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    /// The database dumped by the server's own mysqldump, schema only, with its stored programs.
    fn dump(&self, db: &str) -> String {
        let out = Command::new("docker")
            .args([
                "exec",
                &self.name,
                "mysqldump",
                "-uroot",
                &format!("-p{ROOT}"),
                "--no-data",
                "--routines",
                "--triggers",
                "--events",
                "--databases",
                db,
            ])
            .output()
            .expect("mysqldump");
        assert!(out.status.success(), "mysqldump: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    fn profile(&self, user: &str) -> Profile {
        Profile::new(BTreeMap::from([
            ("host".to_string(), "127.0.0.1".to_string()),
            ("port".to_string(), self.port.clone()),
            ("user".to_string(), user.to_string()),
            ("databases".to_string(), "shop".to_string()),
            ("tls".to_string(), "required".to_string()),
        ]))
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = Command::new("docker").args(["rm", "-f", "-v", &self.name]).output();
    }
}

fn samples() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/samples/shop")
}

/// The schema without what the dump cannot hold (the server's tablespaces and spatial reference systems).
fn as_a_dump_holds_it(mut schema: Schema) -> Schema {
    schema.objects.retain(|o| o.kind != "tablespace" && o.kind != "spatial_reference_system");
    for o in &mut schema.objects {
        let s: ObjectSection = read(&o.engine).expect("a section");
        o.engine = write(&s);
    }
    schema
}

fn live_equals_dump(version: &str) {
    let server = Server::start(version);
    let mut source = std::fs::read_to_string(samples().join("source.sql")).expect("the source");
    if !version.starts_with("8.") {
        source.push_str(&std::fs::read_to_string(samples().join("source97.sql")).expect("the source"));
    }
    server.sql(&source).expect("the shop loads");
    let grants = "SELECT, SHOW VIEW, TRIGGER, EVENT, PROCESS, SHOW_ROUTINE";
    server
        .sql(&format!("CREATE USER 'reader'@'%' IDENTIFIED BY '{READER}'; GRANT {grants} ON *.* TO 'reader'@'%';"))
        .expect("a reader");

    let engine = Mysql::new();
    let live = engine.live().expect("it reads live databases");
    let secret = Secret::new(READER);

    let steps = live.test(&server.profile("reader"), Some(&secret));
    let outcomes: Vec<(StepKind, Outcome)> = steps.iter().map(|s| (s.step, s.outcome)).collect();
    assert_eq!(
        outcomes,
        [
            (StepKind::Reach, Outcome::Passed),
            (StepKind::Secure, Outcome::Warning),
            (StepKind::SignIn, Outcome::Passed),
            (StepKind::Version, Outcome::Passed),
            (StepKind::Rights, Outcome::Passed),
        ],
        "MySQL {version}: {steps:#?}"
    );
    assert!(steps[3].said.contains(&format!("designed for MySQL {version}")), "{}", steps[3].said);

    let wrong = live.test(&server.profile("reader"), Some(&Secret::new("wrong")));
    assert_eq!(wrong[2].outcome, Outcome::Failed, "{wrong:#?}");
    assert!(wrong[3..].iter().all(|s| s.outcome == Outcome::Skipped));
    server
        .sql("CREATE USER 'partial'@'%' IDENTIFIED BY 'partial'; GRANT SELECT ON shop.* TO 'partial'@'%';")
        .expect("a user");
    let partial = live.test(&server.profile("partial"), Some(&Secret::new("partial")));
    assert_eq!(partial[4].outcome, Outcome::Failed, "{:?}", partial[4]);
    assert!(partial[4].said.contains("SHOW VIEW") && partial[4].said.contains("SHOW_ROUTINE"), "{}", partial[4].said);
    let refused = live.read(&server.profile("partial"), Some(&Secret::new("partial")), &[]);
    assert!(
        refused.is_err_and(|e| e.contains("TRIGGER")),
        "a read that would miss the triggers and events it cannot see is refused"
    );
    let root = live.test(&server.profile("root"), Some(&Secret::new(ROOT)));
    assert_eq!(root[4].outcome, Outcome::Warning, "root can change things: {:?}", root[4].said);

    let imported = live.read(&server.profile("reader"), Some(&secret), &[]).expect("the live read");
    assert!(imported.report.adds_up() && imported.report.not_understood.is_empty(), "{:?}", imported.report);
    let kinds: Vec<&str> = imported.schema.objects.iter().map(|o| o.kind.as_str()).collect();
    assert!(kinds.contains(&"tablespace") && kinds.contains(&"spatial_reference_system"), "{kinds:?}");
    assert_eq!(imported.schema.engine.version, version);

    let dump = engine
        .read()
        .expect("it reads")
        .read(&Input::open(&samples().join(format!("schema{version}.sql"))).expect("the dump"))
        .expect("it reads");
    assert_eq!(
        as_a_dump_holds_it(imported.schema).to_json(),
        as_a_dump_holds_it(dump.schema).to_json(),
        "MySQL {version}"
    );
}

#[test]
#[ignore = "needs Docker and the MySQL images"]
fn live_8_0() {
    live_equals_dump("8.0");
}

#[test]
#[ignore = "needs Docker and the MySQL images"]
fn live_8_4() {
    live_equals_dump("8.4");
}

#[test]
#[ignore = "needs Docker and the MySQL images"]
fn live_9_7() {
    live_equals_dump("9.7");
}

#[test]
#[ignore = "needs Docker and the MySQL images"]
fn live_26_10() {
    live_equals_dump("26.10");
}

#[test]
fn a_server_that_does_not_answer_fails_at_reach() {
    let profile = Profile::new(BTreeMap::from([
        ("host".to_string(), "127.0.0.1".to_string()),
        ("port".to_string(), "1".to_string()),
        ("user".to_string(), "nobody".to_string()),
        ("timeout".to_string(), "2".to_string()),
    ]));
    let steps = Mysql::new().live().expect("live").test(&profile, None);
    assert_eq!(steps[0].outcome, Outcome::Failed);
    assert!(steps[1..].iter().all(|s| s.outcome == Outcome::Skipped) && steps.len() == 5);
}

/// Reads SQL text as the engine reads a file.
fn read_text(engine: &Mysql, text: &str, name: &str) -> schema_forge_engine::Imported {
    static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("schema-forge-mysql-{name}-{}-{n}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a folder");
    let file = dir.join(format!("{name}.sql"));
    std::fs::write(&file, text).expect("written");
    let imported = engine.read().expect("it reads").read(&Input::open(&file).expect("the file")).expect("it reads");
    std::fs::remove_dir_all(&dir).expect("removed");
    imported
}

#[test]
#[ignore = "needs Docker and the MySQL images"]
fn a_lending_library_laced_with_stored_programs_8_4() {
    lending("8.4");
}

#[test]
#[ignore = "needs Docker and the MySQL images"]
fn a_lending_library_laced_with_stored_programs_9_7() {
    lending("9.7");
}

/// The lending library in MySQL `version`: every type, every kind of stored program, read live and from its dump as
/// one schema, written, loaded into a fresh server, and dumped again as the same schema, its programs still working.
fn lending(version: &str) {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/samples/lending");
    let mut source = std::fs::read_to_string(dir.join("source.sql")).expect("the source");
    let later = !version.starts_with("8.");
    if later {
        source.push_str(&std::fs::read_to_string(dir.join("source97.sql")).expect("the source"));
    }
    let tag = version.replace('.', "-");
    let first = Server::named(version, &format!("schema-forge-mysql-lending-{tag}"));
    first.sql(&source).expect("the library loads, and its procedures, functions and triggers run");
    assert_eq!(
        first.query("SELECT loans_out, fines FROM lending.members").trim(),
        "0\t0.00",
        "borrowed and given back"
    );
    let audited: u32 = first.query("SELECT COUNT(*) FROM lending.audit").trim().parse().expect("a count");
    // The loan given back, the book tagged, the fine paid; renewing a returned loan changes nothing.
    assert_eq!(audited, 3, "the audit triggers and the procedure wrote what happened");
    first
        .sql("CREATE USER 'reader'@'%' IDENTIFIED BY 'samples-reader'; GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, PROCESS, SHOW_ROUTINE ON *.* TO 'reader'@'%';")
        .expect("a reader");

    let engine = Mysql::new();
    // What MySQL rewrites as it reads it (serial, BINARY, ASCII, year(4), text(N), escapes), read by this engine from
    // the hand-written source, written, and loaded into another database: MySQL makes the same table of both.
    let at = source.find("CREATE TABLE quirks").expect("the quirks table");
    let quirks = &source[at..at + source[at..].find(";\n").expect("its end")];
    let read_quirks = read_text(&engine, &format!("CREATE DATABASE again;\nUSE again;\n{quirks};\n"), "quirks");
    assert!(read_quirks.report.not_understood.is_empty(), "{:?}", read_quirks.report.not_understood);
    let written_quirks = engine.write().expect("writes").schema(&read_quirks.schema).expect("it writes");
    first.sql(&written_quirks).expect("the quirks, as written, load");
    assert_eq!(
        first.query("SHOW CREATE TABLE lending.quirks"),
        first.query("SHOW CREATE TABLE again.quirks"),
        "read and written by the engine, the same table to MySQL:\n{written_quirks}"
    );
    let live = engine.live().expect("live");
    let secret = Secret::new(READER);
    let mut profile = first.profile("reader");
    profile.values.insert("databases".to_string(), "lending".to_string());
    let steps = live.test(&profile, Some(&secret));
    assert!(steps.iter().all(|s| matches!(s.outcome, Outcome::Passed | Outcome::Warning)), "{steps:#?}");

    // Read live, and from the server's own dump: the same schema.
    let from_live = live.read(&profile, Some(&secret), &[]).expect("the live read");
    let from_dump = read_text(&engine, &first.dump("lending"), "dump");
    for i in [&from_live, &from_dump] {
        assert!(i.report.adds_up() && i.report.not_understood.is_empty(), "{:?}", i.report);
    }
    let kinds = |s: &Schema| {
        let mut k: BTreeMap<String, usize> = BTreeMap::new();
        for o in &s.objects {
            *k.entry(o.kind.clone()).or_default() += 1;
        }
        k
    };
    let tables = if later { 17 } else { 16 };
    let want = BTreeMap::from(
        [("table", tables), ("function", 4), ("procedure", 5), ("trigger", 10), ("event", 4), ("view", 5)]
            .map(|(k, n)| (k.to_string(), n)),
    );
    assert_eq!(kinds(&from_dump.schema), want);
    // loans → members and books, shelves → branches, preferences → members, book_tags → books; from 9.7 also
    // book_embeddings → books, written on its column.
    assert_eq!(from_dump.schema.links.len(), if later { 6 } else { 5 });
    // A column of every type MySQL has in this version.
    let types: std::collections::BTreeSet<&str> = from_dump
        .schema
        .objects
        .iter()
        .flat_map(|o| &o.columns)
        .filter_map(|c| engine.types().parse(&c.data_type, version).ok().map(|p| p.family))
        .collect();
    let every: std::collections::BTreeSet<&str> = engine
        .types()
        .catalog()
        .iter()
        .filter(|t| t.available.in_version(version, engine.versions()))
        .map(|t| t.name)
        .collect();
    let missing: Vec<&&str> = every.difference(&types).collect();
    assert!(missing.is_empty(), "MySQL {version}: no column of {missing:?}");
    let live_schema = as_a_dump_holds_it(from_live.schema);
    assert_eq!(live_schema.to_json(), as_a_dump_holds_it(from_dump.schema.clone()).to_json(), "live and dump");

    // Write it, load what was written into a fresh server, dump that: the same schema, and its programs still run.
    let written = engine.write().expect("writes").schema(&from_dump.schema).expect("it writes");
    let second = Server::named(version, &format!("schema-forge-mysql-lending-again-{tag}"));
    second.sql(&written).expect("what the engine wrote loads");
    let again = read_text(&engine, &second.dump("lending"), "again");
    assert_eq!(
        as_a_dump_holds_it(again.schema).to_json(),
        as_a_dump_holds_it(from_dump.schema).to_json(),
        "written, loaded, dumped"
    );
    second
        .sql("USE lending; INSERT INTO members (email, full_name, joined) VALUES ('bo@example.org', 'Bo', '2026-02-01'); \
              INSERT INTO books (isbn, title, author, copies, available) VALUES ('9780000000002', 'Tables', 'T. Codd', 1, 1); \
              CALL borrow(LAST_INSERT_ID(), '9780000000002', @l);")
        .ok();
    assert_eq!(
        second.query("SELECT available FROM lending.books WHERE isbn = '9780000000002'").trim(),
        "0",
        "the trigger lent the copy"
    );
    let refused = second
        .sql("USE lending; CALL borrow((SELECT id FROM members WHERE email = 'bo@example.org'), '9780000000002', @l);");
    assert!(
        refused.is_err_and(|e| e.contains("no copy is available")),
        "the BEFORE INSERT trigger refuses a second loan"
    );
}
