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
    const ALL: [Self; 7] =
        [Self::Model, Self::Interface, Self::Helper, Self::Engine, Self::Registry, Self::App, Self::Tool];

    /// Its name and its article: the one place they are written.
    const fn words(self) -> (&'static str, &'static str) {
        match self {
            Self::Model => ("a", "model"),
            Self::Interface => ("an", "interface"),
            Self::Helper => ("a", "helper"),
            Self::Engine => ("an", "engine"),
            Self::Registry => ("a", "registry"),
            Self::App => ("an", "app"),
            Self::Tool => ("a", "tool"),
        }
    }

    fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|r| r.words().1 == s)
    }

    /// The role with its article, as a sentence says it: `an engine`, `a model`.
    fn a(self) -> String {
        let (article, name) = self.words();
        format!("{article} {name}")
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

impl fmt::Display for Role {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.words().1)
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

/// External crates only some roles may use: parsing SQL is an engine's business; querying is the DataFusion layer's.
/// A name ending in `*` is a family of crates (`datafusion*` is `datafusion`, `datafusion-sql`, `datafusion-expr`…);
/// the first entry that matches a crate decides, so a single crate comes before its family.
const ONLY_FOR: &[(&str, &[Role], &str)] = &[
    ("sqlparser", &[Role::Engine, Role::Helper], "parsing SQL belongs to engines"),
    // Engines map their types to Arrow, and need its types only: never a query engine.
    (
        "arrow-schema",
        &[Role::Interface, Role::Engine, Role::App],
        "Arrow's types are for the interface, engines and apps",
    ),
    ("arrow*", &[Role::App], "Arrow beyond its types belongs to the DataFusion layer"),
    ("datafusion*", &[Role::App], "querying belongs to the DataFusion layer"),
];

/// Whether the crate `name` is `pattern`, or of its family when the pattern ends in `*`.
fn matches_crate(pattern: &str, name: &str) -> bool {
    pattern.strip_suffix('*').map_or(pattern == name, |family| name.starts_with(family))
}

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
    words.sort();
    words.dedup();

    for c in crates {
        let Some(role) = c.role else {
            match &c.role_text {
                Some(t) => {
                    breach(format!("{}: `{t}` is not a role ({})", c.name, Role::ALL.map(|r| r.words().1).join(", ")))
                }
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
        for ext in &c.external {
            if let Some((_, roles, why)) = ONLY_FOR.iter().find(|(p, _, _)| matches_crate(p, ext))
                && !roles.contains(&role)
            {
                breach(format!("{}: {} may not use {ext}: {why}", c.name, role.a()));
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
/// parts of an identifier, at `_`, `-` and capitals (`read_MySqlDialect` is `read`, `My`, `Sql`, `Dialect`), and any
/// run of parts that spells a database, its own `_` aside, is a name: `mysql`, `PostgreSQL`, `pg_dump`,
/// `FromPostgres`, `readMySql`, and for a database `sql_server`, `SqlServer`, `read_sql_server` and `sql-server`. A
/// word that only contains one (`archive`, `sparkline`) is not.
#[must_use]
pub fn names(text: &str, databases: &[String]) -> Vec<(usize, String)> {
    // Spelled as runs of parts are: without `_` or `-`.
    let spelled: Vec<(String, &String)> = databases.iter().map(|d| (d.replace(['_', '-'], ""), d)).collect();
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        for word in
            line.split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_' && ch != '-').filter(|w| !w.is_empty())
        {
            let parts: Vec<&str> = word.split(['_', '-']).filter(|p| !p.is_empty()).flat_map(parts).collect();
            let mut start = 0;
            while start < parts.len() {
                // The longest run from here: `PostgreSQL` is `postgresql`, not `postgres`.
                let mut run = String::new();
                let mut hit = None;
                for (end, part) in parts.iter().enumerate().skip(start) {
                    run.push_str(&part.to_ascii_lowercase());
                    if let Some((_, d)) = spelled.iter().find(|(w, _)| *w == run) {
                        hit = Some((end, *d));
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

/// What one engine's people and data call things, gathered from what every engine declares: its connection field
/// keys, its kind ids and its option keys. Shared code (the apps and the canvas) shows what an engine sends and never
/// names one of these: a connection's `host`, a kind `trigger`, an option `charset` are the engine's business.
#[derive(Debug, Clone, Default)]
pub struct Vocabulary {
    /// Each word, and whose it is (`mysql connection field`).
    pub words: Vec<(String, String)>,
    /// Field names of the API's own types (`canvas/src/api/types.ts`): shared code reads these as members, and a word
    /// that is also one (`table`, `trigger`) is the API's, not the engine's, when read as a member.
    pub api_fields: Vec<String>,
}

/// The words the languages themselves use as values (`typeof x === 'function'`): never an engine's word in code.
const LANGUAGE_WORDS: &[&str] = &["function", "object", "string", "number", "boolean", "undefined", "symbol", "bigint"];

/// The field names declared in TypeScript type text: `name: …` and `name?: …` inside `{ … }`.
#[must_use]
pub fn api_fields(types_ts: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for part in types_ts.split(['{', ',', ';', '\n']) {
        let part = part.trim();
        if let Some((name, _)) = part.split_once(':') {
            let name = name.trim().trim_end_matches('?');
            if !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
                out.push(name.to_string());
            }
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

/// Where `text` (a file of shared code) names an engine's word: as a whole string literal (`"host"`, `'trigger'`,
/// `` `charset` ``), or read as a member (`.host`, `?.host`, `["host"]`) when the API has no field of that name.
/// Comment lines are not code and are not read.
#[must_use]
pub fn vocabulary_in(text: &str, vocabulary: &Vocabulary) -> Vec<(usize, String, String)> {
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        let code = line.trim_start();
        if code.starts_with("//") || code.starts_with('*') || code.starts_with("/*") {
            continue;
        }
        for (word, whose) in &vocabulary.words {
            if LANGUAGE_WORDS.contains(&word.as_str()) {
                continue;
            }
            let literal = literals(line, word).any(|key| !(key && vocabulary.api_fields.contains(word)));
            let member = !vocabulary.api_fields.contains(word) && members(line).any(|m| m == word);
            if literal || member {
                out.push((i + 1, word.clone(), whose.clone()));
            }
        }
    }
    out
}

/// Each place `word` is a whole string literal on `line`, and whether it is in key position there: a key of an object
/// (`"engine": …`) or an index (`row["table"]`), where an API field is named as the API's, not an engine's.
fn literals<'a>(line: &'a str, word: &'a str) -> impl Iterator<Item = bool> + 'a {
    ['"', '\'', '`'].into_iter().flat_map(move |q| {
        let quoted = format!("{q}{word}{q}");
        line.match_indices(&quoted)
            .map(|(i, m)| {
                let before = line[..i].trim_end().chars().next_back();
                let after = line[i + m.len()..].trim_start().chars().next();
                before == Some('[') || after == Some(':')
            })
            .collect::<Vec<_>>()
    })
}

/// The names read as members on `line`: after `.` or `?.`, not after `..`.
fn members(line: &str) -> impl Iterator<Item = &str> {
    line.match_indices('.').filter_map(move |(i, _)| {
        if line[..i].ends_with('.') {
            return None;
        }
        let rest = &line[i + 1..];
        let end = rest.find(|c: char| !c.is_ascii_alphanumeric() && c != '_').unwrap_or(rest.len());
        (end > 0 && !rest.starts_with(|c: char| c.is_ascii_digit())).then(|| &rest[..end])
    })
}

/// The canvas's own code, as (path, text): every TypeScript, style and page file under `canvas/`, but its built
/// output, its packages, its generated API types and its browser tests (which drive each engine by name, as an
/// engine's own tests do).
#[must_use]
pub fn canvas_files(canvas: &Path) -> Vec<(PathBuf, String)> {
    let mut out = Vec::new();
    let mut stack = vec![canvas.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let path = e.path();
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default();
            if path.is_dir() {
                if !matches!(name, "node_modules" | "dist" | "e2e" | "test-results" | "playwright-report") {
                    stack.push(path);
                }
            } else if name != "types.ts"
                && path.extension().and_then(|x| x.to_str()).is_some_and(|x| matches!(x, "ts" | "tsx" | "css" | "html"))
                && let Ok(text) = std::fs::read_to_string(&path)
            {
                out.push((path, text));
            }
        }
    }
    out.sort();
    out
}

/// Every breach in the shared code's `files`: a database named (`databases`, the engines' ids among them), or an
/// engine's word used (`vocabulary`).
#[must_use]
pub fn shared_code(files: &[(PathBuf, String)], databases: &[String], vocabulary: &Vocabulary) -> Vec<Breach> {
    let mut out = Vec::new();
    for (path, text) in files {
        for (line, word) in names(text, databases) {
            out.push(Breach(format!(
                "{}:{line}: names the database `{word}`; that belongs in its engine",
                path.display()
            )));
        }
        for (line, word, whose) in vocabulary_in(text, vocabulary) {
            out.push(Breach(format!(
                "{}:{line}: names `{word}`, a {whose}; shared code shows what an engine declares and never names it",
                path.display()
            )));
        }
    }
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
        assert_eq!(
            check(&c, none),
            [Breach("serve: an app may not use sqlparser: parsing SQL belongs to engines".into())]
        );
        let mut c = good();
        c[3].external.extend(["datafusion-sql".into(), "arrow-array".into(), "arrow-schema".into()]);
        assert_eq!(
            check(&c, none),
            [
                Breach("schema-forge-postgres: an engine may not use datafusion-sql: querying belongs to the DataFusion layer".into()),
                Breach("schema-forge-postgres: an engine may not use arrow-array: Arrow beyond its types belongs to the DataFusion layer".into()),
            ],
            "the whole family is held, and arrow-schema is an engine's to use"
        );
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
        assert_eq!(found("\"sql-server\", schema-forge-engine-sql-server"), ["sql_server", "sql_server"]);
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

    fn vocab() -> Vocabulary {
        Vocabulary {
            words: vec![
                ("host".into(), "mysql connection field".into()),
                ("trigger".into(), "mysql kind".into()),
                ("function".into(), "mysql kind".into()),
            ],
            api_fields: vec!["trigger".into(), "name".into()],
        }
    }

    #[test]
    fn shared_code_names_no_engine_word() {
        let v = vocab();
        let hits = |t: &str| vocabulary_in(t, &v).into_iter().map(|(_, w, _)| w).collect::<Vec<_>>();
        assert_eq!(hits("const at = `${v.host}:${v.port}`"), ["host"]);
        assert_eq!(hits("const at = values?.host ?? ''"), ["host"]);
        assert_eq!(hits("if (o.kind === 'trigger') return"), ["trigger"]);
        assert_eq!(hits("let h = values[\"host\"];"), ["host"]);
        assert_eq!(hits("const v = { host: x, 'host': y }"), ["host"]);
        // An API field named as a key or an index is the API's; as a value, it is still the engine's word.
        assert!(hits("let t = o[\"trigger\"]; let b = json!({ \"trigger\": 1 });").is_empty());
        assert_eq!(hits("if (o.kind === \"trigger\") {}"), ["trigger"]);
        // The API's own member, the language's own word, a comment and a longer word are not the engine's.
        assert!(hits("const t = o.trigger?.on").is_empty());
        assert!(hits("if (typeof f === 'function') f()").is_empty());
        assert!(hits("// the host is the engine's").is_empty());
        assert!(hits("const hostname = 'hosting'").is_empty());
    }

    #[test]
    fn the_api_fields_are_read_from_its_types() {
        let ts =
            "export type Field = { key: string, label?: string, kind: FieldKind, };\nexport type A = { trigger?: B, };";
        assert_eq!(api_fields(ts), ["key", "kind", "label", "trigger"]);
    }

    #[test]
    fn shared_code_names_no_database() {
        let files = vec![(PathBuf::from("canvas/src/a.tsx"), "const label = 'MySQL 8.4'".to_string())];
        let b = shared_code(&files, &["mysql".to_string()], &Vocabulary::default());
        assert_eq!(b.len(), 1, "{b:?}");
        assert!(b[0].0.contains("names the database `mysql`"), "{b:?}");
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
