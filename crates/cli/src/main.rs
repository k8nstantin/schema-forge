//! `schema-forge`: the command line.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand, ValueEnum};
use schema_forge_core::rules::{self, Strength};
use schema_forge_core::{Id, Target};
use schema_forge_dialects::{detect, iceberg, postgres, read_path};
use schema_forge_store::Store;

#[derive(Parser)]
#[command(name = "schema-forge", version, about = "Design database schemas with your coding agent")]
struct Cli {
    /// The workspace folder (default: ~/.schema-forge/workspaces/default).
    #[arg(long, global = true)]
    workspace: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Read a schema dump or a folder of definitions into a schema of the workspace.
    Import {
        /// A PostgreSQL dump (pg_dump), or an Iceberg Spark SQL file or folder.
        path: PathBuf,
        /// The schema to read it into; made if it does not exist.
        #[arg(long)]
        schema: String,
        /// The type, when it cannot be told from the input.
        #[arg(long, value_enum)]
        target: Option<TargetArg>,
    },
    /// Write a schema as its target's SQL.
    Export {
        #[arg(long)]
        schema: String,
        /// Where to write it (default: standard output).
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// List the workspace's schemas.
    Schemas,
    /// Check a schema against the rules linked to it in the perspectives; fails when a Must rule breaks.
    Check {
        #[arg(long)]
        schema: String,
    },
    /// Serve the perspectives of the workspace, and open them.
    Serve {
        #[arg(long, default_value_t = 7410)]
        port: u16,
        /// Do not open the browser.
        #[arg(long)]
        no_open: bool,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum TargetArg {
    Postgres,
    Iceberg,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("schema-forge: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<(), String> {
    let workspace = match cli.workspace {
        Some(w) => w,
        None => default_workspace()?,
    };
    std::fs::create_dir_all(&workspace).map_err(|e| format!("{}: {e}", workspace.display()))?;
    let store = Store::open(&workspace.join("store.redb")).map_err(|e| e.to_string())?;
    match cli.command {
        Command::Import { path, schema, target } => {
            let target = match target {
                Some(TargetArg::Postgres) => Target::Postgres,
                Some(TargetArg::Iceberg) => Target::Iceberg,
                None => detect(&path)?,
            };
            let imported = read_path(&path, target)?;
            if !store.schemas().map_err(|e| e.to_string())?.iter().any(|s| s.name == schema) {
                store.create_schema(&schema, target).map_err(|e| e.to_string())?;
            }
            store.replace_model(&schema, &imported.schema, "import", "import").map_err(|e| e.to_string())?;
            print!("{}", imported.report);
            for problem in schema_forge_core::check(&imported.schema) {
                println!("  finding: {problem}");
            }
            println!("read into schema `{schema}` ({})", target_name(target));
            Ok(())
        }
        Command::Export { schema, out } => {
            let model = store.model(&schema).map_err(|e| e.to_string())?;
            let sql = match model.target {
                Target::Postgres => postgres::generate(&model),
                Target::Iceberg => iceberg::generate(&model),
                Target::Mysql => return Err("writing MySQL comes in milestone 2".to_string()),
            };
            match out {
                Some(path) => std::fs::write(&path, sql).map_err(|e| format!("{}: {e}", path.display())),
                None => {
                    print!("{sql}");
                    Ok(())
                }
            }
        }
        Command::Serve { port, no_open } => {
            let store = std::sync::Arc::new(store);
            let runtime = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
            runtime.block_on(schema_forge_serve::serve(store, port, |addr| {
                let url = format!("http://{addr}");
                println!("Schema Forge is serving {} at {url}", workspace.display());
                if !no_open {
                    open_browser(&url);
                }
            }))
        }
        Command::Check { schema } => check(&store, &schema),
        Command::Schemas => {
            for s in store.schemas().map_err(|e| e.to_string())? {
                println!("{}\t{}", s.name, target_name(s.target));
            }
            Ok(())
        }
    }
}

fn check(store: &Store, schema: &str) -> Result<(), String> {
    let model = store.model(schema).map_err(|e| e.to_string())?;
    let global = store.global_rules().map_err(|e| e.to_string())?;
    let set = store.rules(schema).map_err(|e| e.to_string())?;
    let report = rules::check(&model, &global, &set);
    let cat = rules::catalog();
    for p in &report.problems {
        println!("problem: {p}");
    }
    if report.tallies.is_empty() {
        println!("no rules are linked to `{schema}`: link them in the Rules perspective");
        return Ok(());
    }
    let mut must = 0;
    for (id, t) in &report.tallies {
        let Some(rule) = cat.rule(id).filter(|r| r.rules.is_empty()) else { continue };
        let strength = if rule.strength == Strength::Must { "must  " } else { "should" };
        println!("{strength} {id:<32} {:>6} checked {:>6} break   {}", t.checked, t.breaks, rule.title);
        if rule.strength == Strength::Must {
            must += t.breaks;
        }
    }
    let names: std::collections::HashMap<&Id, &str> = model.tables.iter().map(|t| (&t.id, t.name.as_str())).collect();
    for f in &report.findings {
        println!("  {} @{}: {}", f.rule, names.get(&f.table).copied().unwrap_or(f.table.as_str()), f.message);
    }
    if must > 0 { Err(format!("{must} break a Must rule")) } else { Ok(()) }
}

/// Opens `url` in the default browser; a failure is only reported, the server runs on.
fn open_browser(url: &str) {
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else if cfg!(windows) {
        "explorer"
    } else {
        "xdg-open"
    };
    if let Err(e) = std::process::Command::new(opener).arg(url).spawn() {
        eprintln!("schema-forge: could not open the browser ({e}); open {url}");
    }
}

fn default_workspace() -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME").ok_or("HOME is not set; give --workspace")?;
    Ok(PathBuf::from(home).join(".schema-forge/workspaces/default"))
}

const fn target_name(t: Target) -> &'static str {
    match t {
        Target::Mysql => "mysql",
        Target::Postgres => "postgres",
        Target::Iceberg => "iceberg",
    }
}
