//! Step 13: every owner's folder loaded on PostgreSQL 18 in Docker, as the root's method orders its versions.

use crate::{Finding, Owner, files_in, finding, name, owners, rel, stem};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::Duration;

/// A running container, removed whatever happens.
struct Container(String);

impl Drop for Container {
    fn drop(&mut self) {
        let _ = Command::new("docker").args(["rm", "-f", &self.0]).stdout(Stdio::null()).stderr(Stdio::null()).status();
    }
}

impl Container {
    /// psql on a database with a script on its standard input: what it printed, and its error when it failed.
    fn psql(&self, db: &str, script: &str) -> Result<String, (String, String)> {
        let mut child = Command::new("docker")
            .args(["exec", "-i", &self.0, "psql", "-U", "postgres", "-d", db, "-v", "ON_ERROR_STOP=1", "-q", "-At"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| (String::new(), e.to_string()))?;
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(script.as_bytes());
        }
        let out = child.wait_with_output().map_err(|e| (String::new(), e.to_string()))?;
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        if out.status.success() {
            Ok(stdout)
        } else {
            let err = String::from_utf8_lossy(&out.stderr);
            let message = err.lines().find(|l| l.contains("ERROR:")).unwrap_or(err.trim()).to_string();
            Err((stdout, message.split("ERROR:").last().unwrap_or("").trim().to_string()))
        }
    }

    /// The schema-only dump of a whole database, as schema/dump keeps it (decision schema-dump).
    fn dump_all(&self, db: &str) -> String {
        let out =
            Command::new("docker").args(["exec", &self.0, "pg_dump", "-U", "postgres", "--schema-only", db]).output();
        out.map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default()
    }

    fn dump(&self, db: &str, ns: &str) -> String {
        let out = Command::new("docker")
            .args(["exec", &self.0, "pg_dump", "-U", "postgres", "--schema-only", "-n", ns, db])
            .output();
        out.map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default()
    }
}

/// The image postgres/manifest.toml's [check] image names.
fn image(root: &Path) -> Result<String, String> {
    let text =
        fs::read_to_string(root.join("postgres/manifest.toml")).map_err(|e| format!("postgres/manifest.toml: {e}"))?;
    let doc: toml::Table = text.parse().map_err(|e| format!("postgres/manifest.toml: {e}"))?;
    doc.get("check")
        .and_then(|c| c.get("image"))
        .and_then(|i| i.as_str())
        .map(str::to_string)
        .ok_or_else(|| "postgres/manifest.toml: no [check] image".to_string())
}

fn start(image: &str) -> Result<Container, String> {
    let info = Command::new("docker").args(["info", "--format", "{{.ServerVersion}}"]).output();
    match info {
        Ok(o) if o.status.success() => {}
        Ok(o) => return Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => return Err(e.to_string()),
    }
    // tests run in parallel in one process and the clock may tick in microseconds: a counter keeps each name new
    static STARTED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let name = format!(
        "schema-forge-specs-{}-{}-{}",
        std::process::id(),
        STARTED.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        std::time::UNIX_EPOCH.elapsed().map_or(0, |d| d.as_nanos())
    );
    let run = Command::new("docker")
        .args(["run", "-d", "--rm", "--name", &name, "-e", "POSTGRES_HOST_AUTH_METHOD=trust", image])
        .output()
        .map_err(|e| e.to_string())?;
    if !run.status.success() {
        return Err(String::from_utf8_lossy(&run.stderr).trim().to_string());
    }
    let container = Container(name);
    // the image runs a server of its own while it makes the cluster, then starts the real one: wait for that one
    for _ in 0..240 {
        let logs = Command::new("docker").args(["logs", &container.0]).output();
        let made = logs.is_ok_and(|o| {
            let all = format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
            all.contains("PostgreSQL init process complete")
        });
        if made && container.psql("postgres", "SELECT 1;").is_ok() {
            return Ok(container);
        }
        sleep(Duration::from_millis(250));
    }
    Err("PostgreSQL did not answer within a minute".into())
}

/// An owner's table files, in the order of their foreign keys, ties by file name.
fn tables_in_order(root: &Path, owner: &Owner) -> Vec<(String, String, String)> {
    let ns = owner.namespace();
    let mut tables: Vec<(String, String, BTreeSet<String>)> = files_in(&root.join(&owner.folder), ".sql")
        .into_iter()
        .filter_map(|f| {
            let text = fs::read_to_string(&f).ok()?;
            text.lines().find(|l| l.starts_with("CREATE TABLE "))?;
            let table = format!("{ns}.{}", stem(&f));
            let refs: BTreeSet<String> = text
                .split("REFERENCES ")
                .skip(1)
                .filter_map(|r| r.split_whitespace().next().map(str::to_string))
                .filter(|t| t.starts_with(&format!("{ns}.")) && *t != table)
                .collect();
            Some((rel(root, &f), table, refs))
        })
        .collect();
    let mut done: BTreeSet<String> = BTreeSet::new();
    let mut out = Vec::new();
    while !tables.is_empty() {
        let Some(i) = tables.iter().position(|(_, _, refs)| refs.iter().all(|r| done.contains(r))) else { break };
        let (path, table, _) = tables.remove(i);
        done.insert(table.clone());
        let text = fs::read_to_string(root.join(&path)).unwrap_or_default();
        out.push((path, table, text));
    }
    out.extend(tables.into_iter().map(|(p, t, _)| {
        let text = fs::read_to_string(root.join(&p)).unwrap_or_default();
        (p, t, text)
    }));
    out
}

/// Every file of an owner's version 1, in the method's order, each with its path: the namespace, the tables, for the
/// cortex its functions, the rules, the call that enforces them, the seeds and the grants.
fn version_one(root: &Path, owner: &Owner) -> Vec<(String, String)> {
    let ns = owner.namespace();
    let folder = root.join(&owner.folder);
    let mut parts = vec![(format!("{}/owner.toml", owner.root), format!("CREATE SCHEMA {ns};"))];
    for (path, _, text) in tables_in_order(root, owner) {
        parts.push((path, text));
    }
    if owner.id == "cortex" {
        for f in ["enforce_rules.sql", "grant_roles.sql"] {
            parts.push((format!("{}/{f}", owner.folder), fs::read_to_string(folder.join(f)).unwrap_or_default()));
        }
    }
    for f in files_in(&folder.join("rules"), ".sql") {
        parts.push((rel(root, &f), fs::read_to_string(&f).unwrap_or_default()));
    }
    parts.push((format!("{}/rules", owner.folder), format!("SELECT cortex.enforce_rules('{ns}');")));
    for f in files_in(&folder.join("seeds"), ".sql") {
        parts.push((rel(root, &f), fs::read_to_string(&f).unwrap_or_default()));
    }
    parts.push((format!("{}/owner.toml", owner.root), format!("SELECT cortex.grant_roles('{ns}');")));
    parts
}

/// One script of many files, each announced, as sf_owner, in one transaction.
fn script(parts: &[(String, String)]) -> String {
    let mut s = String::from("BEGIN;\nSET ROLE sf_owner;\n");
    for (path, text) in parts {
        s.push_str(&format!("\\echo @@ {path}\n{text}\n"));
    }
    s.push_str("COMMIT;\n");
    s
}

/// The file that failed: the last one announced before the error.
fn failing(stdout: &str) -> String {
    stdout.lines().filter_map(|l| l.strip_prefix("@@ ")).next_back().unwrap_or("?").to_string()
}

fn apply(c: &Container, db: &str, parts: &[(String, String)], found: &mut Vec<Finding>) -> bool {
    match c.psql(db, &script(parts)) {
        Ok(_) => true,
        Err((out, message)) => {
            finding(found, failing(&out), format!("does not load: {message}"));
            false
        }
    }
}

pub fn check(root: &Path, found: &mut Vec<Finding>) {
    let c = match image(root).and_then(|i| start(&i)) {
        Ok(c) => c,
        Err(message) => {
            finding(found, "docker", format!("not running: {message}"));
            return;
        }
    };
    let roles = "CREATE ROLE sf_owner NOLOGIN; CREATE ROLE sf_service LOGIN; CREATE ROLE sf_agent LOGIN; CREATE ROLE sf_reader LOGIN;";
    if c.psql("postgres", roles).is_err() {
        finding(found, "docker", "not running: the roles could not be made");
        return;
    }
    let all = owners(root);
    let cortex = all[0].clone();
    let ui = all[1].clone();
    let others: Vec<Owner> = all[2..].to_vec();
    let file_of: BTreeMap<String, String> =
        all.iter().flat_map(|o| tables_in_order(root, o).into_iter().map(|(p, t, _)| (t, p))).collect();

    // one database, schema_forge, holding every owner: the cortex (the workspace among it), the ui, every engine and feature;
    // the owner template apart, beside the cortex and the ui, as an engine a contributor copies would be
    let (template, owners_of_the_product): (Vec<Owner>, Vec<Owner>) =
        others.iter().cloned().partition(|o| o.root == "docs/owner-template");
    let mut product = vec![cortex.clone(), ui.clone()];
    product.extend(owners_of_the_product);
    let mut databases: Vec<(String, Vec<Owner>)> = vec![("specs_schema_forge".into(), product)];
    for t in template {
        databases.push(("specs_example".into(), vec![cortex.clone(), ui.clone(), t]));
    }
    let mut dumped: BTreeMap<String, String> = BTreeMap::new();
    for (db, its) in &databases {
        if c.psql("postgres", &format!("CREATE DATABASE {db} OWNER sf_owner;")).is_err() {
            finding(found, db, "does not load: the database could not be made");
            continue;
        }
        let parts: Vec<(String, String)> = its.iter().flat_map(|o| version_one(root, o)).collect();
        if !apply(&c, db, &parts, found) {
            continue;
        }
        keys_to_primary(&c, db, its, &file_of, found);
        rules_hold(&c, db, root, its, found);
        seeds_again(&c, db, root, its, found);
        service_cannot_change(&c, db, its, found);
        if db == "specs_schema_forge" {
            dumped.insert("schema_forge".to_string(), normal(&c.dump_all(db)));
        }
    }
    compare_dumps(root, &dumped, found);

    // an owner with migrations: its versions, applied in order, give exactly its files
    for o in &others {
        versions(&c, root, &[cortex.clone(), ui.clone()], o, found);
    }
}

fn keys_to_primary(
    c: &Container,
    db: &str,
    its: &[Owner],
    file_of: &BTreeMap<String, String>,
    found: &mut Vec<Finding>,
) {
    let namespaces: Vec<String> = its.iter().map(|o| format!("'{}'", o.namespace())).collect();
    let query = format!(
        "SELECT n.nspname || '.' || t.relname, n2.nspname || '.' || r.relname, \
           (SELECT string_agg(a.attname, ',' ORDER BY a.attnum) FROM pg_attribute a WHERE a.attrelid = r.oid AND a.attnum = ANY (k.confkey)) \
         FROM pg_constraint k JOIN pg_class t ON t.oid = k.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace \
         JOIN pg_class r ON r.oid = k.confrelid JOIN pg_namespace n2 ON n2.oid = r.relnamespace \
         WHERE k.contype = 'f' AND n.nspname IN ({}) \
           AND NOT EXISTS (SELECT 1 FROM pg_constraint p WHERE p.conrelid = k.confrelid AND p.contype = 'p' AND p.conkey = k.confkey);",
        namespaces.join(", ")
    );
    if let Ok(out) = c.psql(db, &query) {
        for line in out.lines() {
            let f: Vec<&str> = line.split('|').collect();
            if f.len() == 3 {
                let at = file_of.get(f[0]).cloned().unwrap_or_else(|| f[0].to_string());
                finding(found, at, format!("refers to {} by {}, which is not its primary key", f[1], f[2]));
            }
        }
    }
}

fn rules_hold(c: &Container, db: &str, root: &Path, its: &[Owner], found: &mut Vec<Finding>) {
    for o in its {
        for f in files_in(&root.join(&o.folder).join("rules"), ".sql") {
            let rule = stem(&f);
            let view = format!("{}.broken_{}", o.namespace(), rule.replace('-', "_"));
            if let Ok(out) = c.psql(db, &format!("SELECT count(*) FROM {view};"))
                && out.trim() != "0"
            {
                finding(found, rel(root, &f), format!("rule {rule} lists rows of a new database"));
            }
        }
    }
}

/// A fingerprint of every row of a namespace's tables.
fn fingerprint(c: &Container, db: &str, ns: &str) -> String {
    let tables = c
        .psql(db, &format!("SELECT tablename FROM pg_tables WHERE schemaname = '{ns}' ORDER BY 1;"))
        .unwrap_or_default();
    let mut all = String::new();
    for t in tables.lines() {
        let q = format!(
            "SELECT count(*) || ':' || coalesce(md5(string_agg(x::text, '|' ORDER BY x::text)), '') FROM {ns}.{t} x;"
        );
        all.push_str(&format!("{t}={}\n", c.psql(db, &q).unwrap_or_default().trim()));
    }
    all
}

fn seeds_again(c: &Container, db: &str, root: &Path, its: &[Owner], found: &mut Vec<Finding>) {
    for o in its {
        for f in files_in(&root.join(&o.folder).join("seeds"), ".sql") {
            let before = fingerprint(c, db, &o.namespace());
            let text = fs::read_to_string(&f).unwrap_or_default();
            let again = c.psql(db, &format!("SET ROLE sf_owner;\n{text}"));
            if again.is_err() || fingerprint(c, db, &o.namespace()) != before {
                finding(found, rel(root, &f), "applying it again changes the database");
            }
        }
    }
}

fn service_cannot_change(c: &Container, db: &str, its: &[Owner], found: &mut Vec<Finding>) {
    // the app's role and the coding agent's: each writes rows and neither may change the schema
    for role in ["sf_service", "sf_agent"] {
        for o in its {
            let ns = o.namespace();
            let attempt = format!("SET ROLE {role}; CREATE TABLE {ns}.specs_service_attempt (id text);");
            if c.psql(db, &attempt).is_ok() {
                finding(found, &o.root, format!("{role} can change the schema"));
                let _ = c.psql(db, &format!("DROP TABLE {ns}.specs_service_attempt;"));
            }
        }
    }
}

/// The lines of a namespace's schema-only dump that describe it, sorted.
fn described(dump: &str) -> Vec<String> {
    let mut lines: Vec<String> = dump
        .lines()
        .map(str::trim_end)
        .filter(|l| {
            !l.is_empty() && !l.starts_with("--") && !l.starts_with("\\restrict") && !l.starts_with("\\unrestrict")
        })
        .map(str::to_string)
        .collect();
    lines.sort();
    lines
}

fn versions(c: &Container, root: &Path, core: &[Owner], o: &Owner, found: &mut Vec<Finding>) {
    let dir = root.join(&o.folder).join("migrations");
    let files = files_in(&dir, ".sql");
    if files.is_empty() {
        return;
    }
    let mut ordered: Vec<(u64, String, String)> = files
        .iter()
        .filter_map(|f| {
            let n = name(f).split_once('_')?.0.parse().ok()?;
            Some((n, rel(root, f), fs::read_to_string(f).ok()?))
        })
        .collect();
    ordered.sort();
    let db = format!("specs_{}_versions", o.id);
    if c.psql("postgres", &format!("CREATE DATABASE {db} OWNER sf_owner;")).is_err() {
        return;
    }
    let ns = o.namespace();
    let mut parts: Vec<(String, String)> = core.iter().flat_map(|k| version_one(root, k)).collect();
    let mut grant_after_first = true;
    for (_, path, text) in &ordered {
        parts.push((path.clone(), text.clone()));
        if grant_after_first {
            parts.push((format!("{}/owner.toml", o.root), format!("SELECT cortex.grant_roles('{ns}');")));
            grant_after_first = false;
        }
    }
    if !apply(c, &db, &parts, found) {
        return;
    }
    let files_dump = described(&c.dump(&format!("specs_{}", o.id), &ns));
    let versions_dump = described(&c.dump(&db, &ns));
    if files_dump != versions_dump {
        let first = files_dump
            .iter()
            .zip(versions_dump.iter())
            .find(|(a, b)| a != b)
            .map(|(a, _)| a.clone())
            .or_else(|| files_dump.get(versions_dump.len()).cloned())
            .or_else(|| versions_dump.get(files_dump.len()).cloned())
            .unwrap_or_default();
        finding(found, &o.root, format!("its versions do not give its files: {first}"));
    }
}

/// A dump without what changes from run to run: the versions it names and pg_dump's restrict key, blank lines at
/// either end trimmed.
fn normal(dump: &str) -> String {
    let kept: Vec<&str> = dump
        .lines()
        .filter(|l| !["-- Dumped from", "-- Dumped by", "\\restrict", "\\unrestrict"].iter().any(|p| l.starts_with(p)))
        .collect();
    format!("{}\n", kept.join("\n").trim())
}

/// Every database the design makes, as dumped, against schema/dump/<name>.sql after its two header lines.
fn compare_dumps(root: &Path, dumped: &BTreeMap<String, String>, found: &mut Vec<Finding>) {
    for (name, now) in dumped {
        let at = format!("schema/dump/{name}.sql");
        let Ok(kept) = fs::read_to_string(root.join(&at)) else {
            finding(found, &at, "missing");
            continue;
        };
        let body = kept.splitn(3, '\n').nth(2).unwrap_or("");
        if body != now {
            let first = body
                .lines()
                .zip(now.lines())
                .find(|(a, b)| a != b)
                .map_or_else(|| "one ends before the other".to_string(), |(a, b)| format!("{a} / {b}"));
            finding(found, &at, format!("the database drifted from its dump: {first}"));
        }
    }
    for f in files_in(&root.join("schema/dump"), ".sql") {
        if !dumped.contains_key(&stem(&f)) {
            finding(found, rel(root, &f), "no database of the design gives it");
        }
    }
}
