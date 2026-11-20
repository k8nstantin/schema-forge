//! `schema-forge`: the command line.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Parser, Subcommand, ValueEnum};
use schema_forge_core::Target;
use schema_forge_dialects::{Imported, iceberg, postgres};
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
            let imported = read(&path, target)?;
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
        Command::Schemas => {
            for s in store.schemas().map_err(|e| e.to_string())? {
                println!("{}\t{}", s.name, target_name(s.target));
            }
            Ok(())
        }
    }
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

/// A folder is Iceberg definitions; a file says what it is (pg_dump's header, or `USING iceberg`).
fn detect(path: &Path) -> Result<Target, String> {
    if path.is_dir() {
        return Ok(Target::Iceberg);
    }
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if text.contains("PostgreSQL database dump") {
        Ok(Target::Postgres)
    } else if text.to_ascii_lowercase().contains("using iceberg") {
        Ok(Target::Iceberg)
    } else {
        Err(format!("{}: say what it is with --target postgres or --target iceberg", path.display()))
    }
}

fn read(path: &Path, target: Target) -> Result<Imported, String> {
    let file = || std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()));
    match target {
        Target::Postgres => postgres::import(&file()?).map_err(|e| e.to_string()),
        Target::Iceberg if path.is_dir() => iceberg::import_folder(path).map_err(|e| e.to_string()),
        Target::Iceberg => iceberg::import(&file()?).map_err(|e| e.to_string()),
        Target::Mysql => Err("reading MySQL comes in milestone 2".to_string()),
    }
}
