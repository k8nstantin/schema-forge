//! The design in docs/engines.md, checked on the code: what each crate is, what it may depend on, and where a database
//! may be named. `cargo test` runs it on the workspace (tests/workspace.rs), so a breach fails the build.

use std::fmt;
use std::path::{Path, PathBuf};

/// What a crate is, declared in its `[package.metadata.schema-forge]` as `role = "…"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// The skeleton every database shares.
    Model,
    /// The plugin interface: the trait, its facets, the registry.
    Interface,
    /// Code engines may share, such as reading SQL statements; never a database's own knowledge.
    Helper,
    /// One database, whole.
    Engine,
    /// The engines Schema Forge ships with, registered.
    Registry,
    /// The store, the server, the MCP, the command line: they ask the registry, never one engine.
    App,
    /// Checks of the code itself.
    Tool,
}

impl Role {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "model" => Self::Model,
            "interface" => Self::Interface,
            "helper" => Self::Helper,
            "engine" => Self::Engine,
            "registry" => Self::Registry,
            "app" => Self::App,
            "tool" => Self::Tool,
            _ => return None,
        })
    }

    /// The roles a crate of this role may depend on; `None` for any.
    const fn may_depend_on(self) -> Option<&'static [Role]> {
        Some(match self {
            Self::Model => &[],
            Self::Interface => &[Self::Model],
            Self::Helper => &[Self::Model, Self::Interface],
            Self::Engine => &[Self::Model, Self::Interface, Self::Helper],
            Self::Registry => &[Self::Model, Self::Interface, Self::Engine],
            Self::App => &[Self::Model, Self::Interface, Self::Registry, Self::App],
            Self::Tool => return None,
        })
    }

    /// Whether this role's code may name a database: an engine names its own, the registry names the engines.
    const fn may_name_databases(self) -> bool {
        matches!(self, Self::Engine | Self::Registry | Self::Tool)
    }
}

impl Role {
    /// The role with its article, as a sentence says it: `an engine`, `a model`.
    fn a(self) -> String {
        let name = self.to_string();
        let article = if name.starts_with(['a', 'e', 'i', 'o', 'u']) { "an" } else { "a" };
        format!("{article} {name}")
    }
}

impl fmt::Display for Role {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Model => "model",
            Self::Interface => "interface",
            Self::Helper => "helper",
            Self::Engine => "engine",
            Self::Registry => "registry",
            Self::App => "app",
            Self::Tool => "tool",
        })
    }
}

/// Databases and their tools, by the words code would name them with. An engine adds its own id to these.
pub const DATABASES: &[&str] = &[
    "bigquery",
    "clickhouse",
    "cockroach",
    "cockroachdb",
    "databricks",
    "duckdb",
    "hive",
    "iceberg",
    "mariadb",
    "mssql",
    "mysql",
    "mysqldump",
    "oracle",
    "pg",
    "pgdump",
    "postgres",
    "postgresql",
    "redshift",
    "snowflake",
    "spark",
    "sqlite",
    "sqlserver",
    "teradata",
    "tidb",
    "trino",
];

/// External crates only some roles may use: parsing SQL is an engine's business.
const ONLY_FOR: &[(&str, &[Role])] = &[("sqlparser", &[Role::Engine, Role::Helper])];

/// One crate of the workspace, as the check sees it.
#[derive(Debug, Clone)]
pub struct Crate {
    pub name: String,
    /// The folder holding its `Cargo.toml`, relative to the workspace.
    pub dir: PathBuf,
    /// `None` when it declares no role, or one that is not known.
    pub role: Option<Role>,
    /// The role as written, for the message when it is not known.
    pub role_text: Option<String>,
    /// An engine's database id (`database = "…"`).
    pub database: Option<String>,
    /// The workspace crates it depends on, by name.
    pub depends_on: Vec<String>,
    /// The crates from outside the workspace it depends on, by name.
    pub external: Vec<String>,
}

/// A place the design is broken.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Breach(pub String);

impl fmt::Display for Breach {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Every breach of the design among `crates`; `source` gives each crate's files as (path, text).
pub fn check(crates: &[Crate], source: impl Fn(&Crate) -> Vec<(PathBuf, String)>) -> Vec<Breach> {
    let mut out = Vec::new();
    let mut breach = |s: String| out.push(Breach(s));
    let role_of = |name: &str| crates.iter().find(|c| c.name == name).and_then(|c| c.role);
    let mut words: Vec<String> = DATABASES.iter().map(|w| (*w).to_string()).collect();
    words.extend(crates.iter().filter_map(|c| c.database.as_deref().map(str::to_ascii_lowercase)));

    for c in crates {
        let Some(role) = c.role else {
            match &c.role_text {
                Some(t) => breach(format!(
                    "{}: `{t}` is not a role (model, interface, helper, engine, registry, app, tool)",
                    c.name
                )),
                None => breach(format!("{}: declares no role in [package.metadata.schema-forge]", c.name)),
            }
            continue;
        };
        let in_engines = c.dir.starts_with("engines");
        if role == Role::Engine && !in_engines {
            breach(format!("{}: an engine lives in engines/, not {}", c.name, c.dir.display()));
        }
        if role != Role::Engine && in_engines {
            breach(format!("{}: only engines live in engines/; this is {}", c.name, role.a()));
        }
        match (&c.database, role) {
            (None, Role::Engine) => breach(format!("{}: an engine says its database id (database = \"…\")", c.name)),
            (Some(d), Role::Engine)
                if d.is_empty() || !d.chars().all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_') =>
            {
                breach(format!("{}: the database id `{d}` is not lowercase letters, digits and `_`", c.name));
            }
            (Some(_), r) if r != Role::Engine => {
                breach(format!("{}: only an engine says a database; this is {}", c.name, r.a()))
            }
            _ => {}
        }
        if let Some(allowed) = role.may_depend_on() {
            for d in &c.depends_on {
                match role_of(d) {
                    Some(r) if allowed.contains(&r) => {}
                    Some(r) => breach(format!("{}: {} may not depend on {d}, {}", c.name, role.a(), r.a())),
                    None => breach(format!("{}: depends on {d}, which declares no role", c.name)),
                }
            }
        }
        for (ext, roles) in ONLY_FOR {
            if c.external.iter().any(|e| e == ext) && !roles.contains(&role) {
                breach(format!("{}: {} may not use {ext}; that belongs to engines", c.name, role.a()));
            }
        }
        if !role.may_name_databases() {
            for (path, text) in source(c) {
                for (line, word) in names(&text, &words) {
                    breach(format!(
                        "{}:{line}: names the database `{word}`; that belongs in its engine",
                        path.display()
                    ));
                }
            }
        }
    }
    // One crate per database, never one per version: a version lives in its database's crate.
    let mut engines: Vec<(String, &str)> = crates
        .iter()
        .filter(|c| c.role == Some(Role::Engine))
        .filter_map(|c| c.database.as_deref().map(|d| (d.to_ascii_lowercase(), c.name.as_str())))
        .collect();
    engines.sort_unstable();
    for pair in engines.windows(2) {
        if pair[0].0 == pair[1].0 {
            breach(format!(
                "{} and {} both say the database `{}`: one crate per database, its versions inside it",
                pair[0].1, pair[1].1, pair[0].0
            ));
        }
    }
    out
}

/// The databases `text` names, by line. Words are split at everything but letters, digits and `_`, then into the
/// parts of an identifier, at `_` and at capitals (`read_MySqlDialect` is `read`, `My`, `Sql`, `Dialect`), and any
/// run of parts that spells a database, its own `_` aside, is a name: `mysql`, `PostgreSQL`, `pg_dump`,
/// `FromPostgres`, `readMySql`, and for a database `sql_server`, `SqlServer` and `read_sql_server`. A word that only
/// contains one (`archive`, `sparkline`) is not.
#[must_use]
pub fn names(text: &str, databases: &[String]) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        for word in line.split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_').filter(|w| !w.is_empty()) {
            let parts: Vec<&str> = word.split('_').filter(|p| !p.is_empty()).flat_map(parts).collect();
            let mut start = 0;
            while start < parts.len() {
                // The longest run from here: `PostgreSQL` is `postgresql`, not `postgres`.
                let mut run = String::new();
                let mut hit = None;
                for (end, part) in parts.iter().enumerate().skip(start) {
                    run.push_str(&part.to_ascii_lowercase());
                    if let Some(d) = databases.iter().find(|d| d.replace('_', "") == run) {
                        hit = Some((end, d));
                    }
                }
                match hit {
                    Some((end, d)) => {
                        out.push((i + 1, d.clone()));
                        start = end + 1;
                    }
                    None => start += 1,
                }
            }
        }
    }
    out
}

/// An identifier's parts: split before a capital that follows a small letter or a digit, before the last capital of
/// a run of capitals followed by a small letter (`SQLParser` is `SQL` and `Parser`), and between letters and digits.
fn parts(word: &str) -> Vec<&str> {
    let b = word.as_bytes();
    let mut out = Vec::new();
    let mut from = 0;
    for i in 1..b.len() {
        let (p, c) = (b[i - 1], b[i]);
        let next_small = b.get(i + 1).is_some_and(u8::is_ascii_lowercase);
        let cut = (c.is_ascii_uppercase() && (p.is_ascii_lowercase() || p.is_ascii_digit()))
            || (c.is_ascii_uppercase() && p.is_ascii_uppercase() && next_small)
            || (c.is_ascii_digit() != p.is_ascii_digit());
        if cut {
            out.push(&word[from..i]);
            from = i;
        }
    }
    out.push(&word[from..]);
    out
}

/// The workspace's crates, from `cargo metadata` run in `root`.
///
/// # Errors
/// When cargo cannot be run or answers something that is not metadata.
pub fn workspace(root: &Path) -> Result<Vec<Crate>, String> {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_string());
    let out = std::process::Command::new(cargo)
        .args(["metadata", "--format-version", "1", "--no-deps"])
        .current_dir(root)
        .output()
        .map_err(|e| format!("cargo metadata: {e}"))?;
    if !out.status.success() {
        return Err(format!("cargo metadata: {}", String::from_utf8_lossy(&out.stderr)));
    }
    let meta: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|e| format!("cargo metadata: {e}"))?;
    let root = std::fs::canonicalize(root).map_err(|e| format!("{}: {e}", root.display()))?;
    let packages = meta["packages"].as_array().ok_or("cargo metadata: no packages")?;
    let mut crates = Vec::new();
    for p in packages {
        let manifest = PathBuf::from(p["manifest_path"].as_str().ok_or("a package without a manifest")?);
        let dir = manifest.parent().ok_or("a manifest without a folder")?;
        let ours = &p["metadata"]["schema-forge"];
        let role_text = ours["role"].as_str().map(str::to_string);
        let deps = p["dependencies"].as_array().map(Vec::as_slice).unwrap_or_default();
        crates.push(Crate {
            name: p["name"].as_str().unwrap_or_default().to_string(),
            dir: dir.strip_prefix(&root).unwrap_or(dir).to_path_buf(),
            role: role_text.as_deref().and_then(Role::parse),
            role_text,
            database: ours["database"].as_str().map(str::to_string),
            depends_on: deps
                .iter()
                .filter(|d| d["path"].is_string())
                .filter_map(|d| d["name"].as_str().map(str::to_string))
                .collect(),
            external: deps
                .iter()
                .filter(|d| !d["path"].is_string())
                .filter_map(|d| d["name"].as_str().map(str::to_string))
                .collect(),
        });
    }
    Ok(crates)
}

/// Every Rust file and manifest under `dir`, as (path, text), skipping build output.
#[must_use]
pub fn files(dir: &Path) -> Vec<(PathBuf, String)> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let path = e.path();
            if path.is_dir() {
                if path.file_name().is_some_and(|n| n != "target") {
                    stack.push(path);
                }
            } else if path.extension().is_some_and(|x| x == "rs")
                && let Ok(text) = std::fs::read_to_string(&path)
            {
                out.push((path, text));
            }
        }
    }
    out.sort();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn krate(name: &str, dir: &str, role: &str, deps: &[&str]) -> Crate {
        Crate {
            name: name.to_string(),
            dir: PathBuf::from(dir),
            role: Role::parse(role),
            role_text: Some(role.to_string()),
            database: (role == "engine").then(|| name.trim_start_matches("schema-forge-").to_string()),
            depends_on: deps.iter().map(|d| (*d).to_string()).collect(),
            external: Vec::new(),
        }
    }

    fn good() -> Vec<Crate> {
        vec![
            krate("model", "crates/model", "model", &[]),
            krate("engine", "crates/engine", "interface", &["model"]),
            krate("sql", "crates/sql", "helper", &["model", "engine"]),
            krate("schema-forge-postgres", "engines/postgres", "engine", &["model", "engine", "sql"]),
            krate("schema-forge-mysql", "engines/mysql", "engine", &["model", "engine", "sql"]),
            krate("engines", "crates/engines", "registry", &["engine", "schema-forge-postgres", "schema-forge-mysql"]),
            krate("store", "crates/store", "app", &["model"]),
            krate("serve", "crates/serve", "app", &["model", "engine", "engines", "store"]),
        ]
    }

    fn none(_: &Crate) -> Vec<(PathBuf, String)> {
        Vec::new()
    }

    #[test]
    fn the_design_as_written_passes() {
        assert_eq!(check(&good(), none), Vec::new());
    }

    #[test]
    fn an_engine_never_depends_on_another() {
        let mut c = good();
        c[4].depends_on.push("schema-forge-postgres".into());
        assert_eq!(
            check(&c, none),
            [Breach("schema-forge-mysql: an engine may not depend on schema-forge-postgres, an engine".into())]
        );
    }

    #[test]
    fn the_apps_ask_the_registry_never_one_engine() {
        let mut c = good();
        c[7].depends_on.push("schema-forge-postgres".into());
        assert_eq!(check(&c, none).len(), 1);
    }

    #[test]
    fn the_model_depends_on_nothing_of_ours() {
        let mut c = good();
        c[0].depends_on.push("engine".into());
        assert_eq!(check(&c, none), [Breach("model: a model may not depend on engine, an interface".into())]);
    }

    #[test]
    fn every_crate_declares_a_known_role() {
        let mut c = good();
        c[6].role = None;
        c[6].role_text = None;
        c[7].role = None;
        c[7].role_text = Some("server".into());
        let b = check(&c, none);
        assert!(b.iter().any(|b| b.0.contains("store: declares no role")), "{b:?}");
        assert!(b.iter().any(|b| b.0.contains("`server` is not a role")), "{b:?}");
    }

    #[test]
    fn engines_live_in_engines_and_say_their_database() {
        let mut c = good();
        c[3].dir = PathBuf::from("crates/postgres");
        c[4].database = None;
        c[6].dir = PathBuf::from("engines/store");
        let b = check(&c, none);
        assert_eq!(b.len(), 3, "{b:?}");
    }

    #[test]
    fn one_crate_per_database_never_one_per_version() {
        let mut c = good();
        let mut v4 = krate("schema-forge-postgres-v4", "engines/postgres-v4", "engine", &["model", "engine"]);
        v4.database = Some("postgres".into());
        c.push(v4);
        assert_eq!(
            check(&c, none),
            [Breach(
                "schema-forge-postgres and schema-forge-postgres-v4 both say the database `postgres`: one crate per \
                 database, its versions inside it"
                    .into()
            )]
        );
    }

    #[test]
    fn parsing_sql_belongs_to_engines() {
        let mut c = good();
        c[7].external.push("sqlparser".into());
        c[3].external.push("sqlparser".into());
        assert_eq!(check(&c, none), [Breach("serve: an app may not use sqlparser; that belongs to engines".into())]);
    }

    #[test]
    fn a_database_is_named_only_in_its_engine() {
        let c = good();
        let src = |k: &Crate| match k.name.as_str() {
            "model" => {
                vec![(PathBuf::from("crates/model/src/lib.rs"), "// a schema\nlet t = MySqlDialect {};\n".into())]
            }
            "schema-forge-postgres" => {
                vec![(PathBuf::from("engines/postgres/src/lib.rs"), "PostgreSQL pg_dump".into())]
            }
            _ => Vec::new(),
        };
        assert_eq!(
            check(&c, src),
            [Breach("crates/model/src/lib.rs:2: names the database `mysql`; that belongs in its engine".into())]
        );
    }

    #[test]
    fn database_ids_are_lowercase_and_compared_so() {
        let mut c = good();
        c[4].database = Some("Postgres".into());
        let b = check(&c, none);
        assert!(
            b.iter()
                .any(|b| b.0
                    == "schema-forge-mysql: the database id `Postgres` is not lowercase letters, digits and `_`"),
            "{b:?}"
        );
        assert!(b.iter().any(|b| b.0.contains("both say the database `postgres`")), "{b:?}");
        let mut c = good();
        c[6].database = Some("x".into());
        assert_eq!(check(&c, none), [Breach("store: only an engine says a database; this is an app".into())]);
    }

    #[test]
    fn a_database_id_with_an_underscore_is_found_however_it_is_written() {
        let words = vec!["sql_server".to_string()];
        let found = |t: &str| names(t, &words).into_iter().map(|(_, w)| w).collect::<Vec<_>>();
        assert_eq!(found("fn read_sql_server_dump() -> SqlServer"), ["sql_server", "sql_server"]);
        assert_eq!(found("sql server, sqlservers"), Vec::<String>::new());
    }

    #[test]
    fn names_hide_in_no_identifier() {
        let words: Vec<String> = DATABASES.iter().map(|w| (*w).to_string()).collect();
        let found = |t: &str| names(t, &words).into_iter().map(|(_, w)| w).collect::<Vec<_>>();
        assert_eq!(found("fn readMySql() -> FromPostgres"), ["mysql", "postgres"]);
        assert_eq!(
            found("ToIceberg IsSnowflake MYSQL_DUMP SQLiteParser"),
            ["iceberg", "snowflake", "mysqldump", "sqlite"]
        );
        assert_eq!(found("let iceberg3 = PgDump::new(); Iceberg3Table"), ["iceberg", "pgdump", "iceberg"]);
        assert_eq!(found("upgrade frompg toiceberg"), Vec::<String>::new(), "a lowercase run is one word");
    }

    #[test]
    fn names_are_words_not_parts_of_words() {
        let words: Vec<String> = DATABASES.iter().map(|w| (*w).to_string()).collect();
        let found = |t: &str| names(t, &words).into_iter().map(|(_, w)| w).collect::<Vec<_>>();
        assert_eq!(found("PostgreSQL, Iceberg and mysql"), ["postgresql", "iceberg", "mysql"]);
        assert_eq!(found("pg_dump IcebergTable read_mysqldump"), ["pgdump", "iceberg", "mysqldump"]);
        assert_eq!(found("an archive of hives, a sparkline, the oracles"), Vec::<String>::new());
        assert_eq!(found("Hive and SPARK"), ["hive", "spark"]);
    }
}
