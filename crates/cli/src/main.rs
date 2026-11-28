//! `schema-forge`, the one binary. `check` signs in to `schema_forge` as every account in the accounts file and reports
//! what each is and sees; it changes nothing. `import` reads a live server into a new design, in one turn. `write` prints
//! a design as the SQL its engine loads.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use anyhow::Context;
use clap::{Args, Parser, Subcommand};
use schema_forge_core::{Cortex, NewDesign, TurnKind};
use schema_forge_engine::{Engine, ImportReport, Registry, Source};
use schema_forge_engine_mysql::Mysql;
use schema_forge_store::{Account, Accounts, Endpoint, Store, Tls};

#[derive(Parser)]
#[command(
    name = "schema-forge",
    version,
    about = "SchemaForge: design databases with people and agents."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

/// Where the store is and who signs in.
#[derive(Args)]
struct Where {
    /// The store's host, or the folder of its Unix socket.
    #[arg(long, default_value = "127.0.0.1")]
    host: String,
    /// The store's port.
    #[arg(long, default_value_t = 5432)]
    port: u16,
    /// The accounts file the installer wrote (mode 600).
    #[arg(long, default_value = "~/schema-forge-lab-private/local-accounts.env")]
    accounts_file: String,
}

#[derive(Subcommand)]
enum Command {
    /// Signs in to `schema_forge` as every account in the accounts file and reports; changes nothing.
    Check {
        #[command(flatten)]
        at: Where,
        /// Require TLS.
        #[arg(long)]
        tls: bool,
    },
    /// Reads a live server into a new design, in one import turn, and prints what it did. A MySQL password comes only
    /// from the environment variable named, never from an argument.
    Import {
        /// The engine of the server.
        #[arg(long)]
        engine: String,
        /// The server: `mysql://user@host:port`.
        #[arg(long)]
        source: String,
        /// The new design's name.
        #[arg(long)]
        design: String,
        /// The flavor, when the server cannot tell it (a managed service); read from the server otherwise.
        #[arg(long)]
        flavor: Option<String>,
        /// Require TLS to the server.
        #[arg(long)]
        tls: bool,
        /// How many connections the read may open at once (one is the gentlest).
        #[arg(long, default_value_t = 4)]
        connections: usize,
        /// The environment variable that holds the server's password.
        #[arg(long)]
        password_env: Option<String>,
        #[command(flatten)]
        at: Where,
    },
    /// Prints a design as the SQL its engine loads.
    Write {
        /// The design's name.
        #[arg(long)]
        design: String,
        #[command(flatten)]
        at: Where,
        /// Require TLS to the store.
        #[arg(long)]
        tls: bool,
    },
}

#[tokio::main]
async fn main() -> ExitCode {
    let ran = match Cli::parse().command {
        Command::Check { at, tls } => check(at, tls).await,
        Command::Import {
            engine,
            source,
            design,
            flavor,
            tls,
            connections,
            password_env,
            at,
        } => {
            import(
                at,
                &engine,
                &source,
                &design,
                flavor.as_deref(),
                tls,
                connections,
                password_env.as_deref(),
            )
            .await
        }
        Command::Write { design, at, tls } => write(at, &design, tls).await,
    };
    match ran {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            println!("FAIL  {e:#}");
            ExitCode::FAILURE
        }
    }
}

fn expand(path: &str) -> PathBuf {
    match (path.strip_prefix("~/"), std::env::var_os("HOME")) {
        (Some(rest), Some(home)) => PathBuf::from(home).join(rest),
        _ => PathBuf::from(path),
    }
}

/// The binary's engines.
fn registry() -> Registry {
    Registry::new().with(Box::new(Mysql))
}

fn store_at(at: &Where, tls: bool) -> anyhow::Result<Store> {
    let accounts = Accounts::read(&expand(&at.accounts_file))?;
    let mut endpoint = Endpoint::new(at.host.clone(), at.port);
    if tls {
        endpoint.tls = Tls::Require;
    }
    Ok(Store::new(endpoint, accounts))
}

/// Each account signs in, and says who it is, the server's version, the cortex's version (the cortex's accounts; a
/// plugin's may not read the plugs, by least privilege) and how many designs it sees (a plugin's, its own engine's
/// alone). True when every account did.
async fn check(at: Where, tls: bool) -> anyhow::Result<bool> {
    let accounts = Accounts::read(&expand(&at.accounts_file))?;
    let mut endpoint = Endpoint::new(at.host, at.port);
    if tls {
        endpoint.tls = Tls::Require;
    }
    println!("== schema_forge on {}:{}", endpoint.host, endpoint.port);
    let held: Vec<Account> = accounts.accounts().cloned().collect();
    let store = Store::new(endpoint, accounts).with_pool_size(1);
    let mut failed = 0;
    for account in &held {
        let cortex = if matches!(account, Account::Plugin(_)) {
            "NULL::int4"
        } else {
            "(SELECT version FROM cortex.plugins WHERE id = 'cortex')"
        };
        let sql = format!(
            "SELECT current_user::text, current_setting('server_version'), {cortex}, (SELECT count(*) FROM cortex.designs)"
        );
        let seen = store
            .read(account, async |tx| {
                let row = tx.query_one(&sql, &[]).await?;
                Ok((
                    row.get::<_, String>(0),
                    row.get::<_, String>(1),
                    row.get::<_, Option<i32>>(2),
                    row.get::<_, i64>(3),
                ))
            })
            .await;
        match seen {
            Ok((user, server, cortex, designs)) if user == account.role() => println!(
                "  pass  {user} signs in: PostgreSQL {server}, {}sees {designs} designs",
                cortex.map_or_else(String::new, |v| format!("cortex version {v}, "))
            ),
            Ok((user, ..)) => {
                failed += 1;
                println!("  FAIL  {account} signed in as {user}");
            }
            Err(e) => {
                failed += 1;
                println!("  FAIL  {account}: {e}");
            }
        }
    }
    println!(
        "{}  check: {} of {} accounts",
        if failed == 0 { "pass" } else { "FAIL" },
        held.len() - failed,
        held.len()
    );
    Ok(failed == 0)
}

/// What an import made.
#[derive(Debug)]
struct Imported {
    design: schema_forge_core::DesignId,
    turn: i32,
    flavor: String,
    report: ImportReport,
}

/// Makes a design for the server (its version and flavor read first), opens an import turn as the app, imports into it
/// and commits. When the import fails the turn, which holds no operation, is rejected, so the design is never left held
/// by it; the error comes back.
async fn import_design(
    cortex: &Cortex,
    engine: &dyn Engine,
    source: &Source,
    name: &str,
    flavor: Option<&str>,
) -> anyhow::Result<Imported> {
    let by = Account::Service;
    let probe = engine
        .probe(cortex.store(), source)
        .await
        .context("reading the server's version")?;
    let flavor = flavor.map_or(probe.flavor, str::to_string);
    let design = cortex
        .create_design(&NewDesign {
            name: name.to_string(),
            engine: engine.id().to_string(),
            version: probe.version,
            flavor: flavor.clone(),
            comment: None,
        })
        .await
        .context("making the design")?;
    let turn = cortex
        .open_turn(
            &by,
            design.id,
            design.main,
            TurnKind::Import,
            "schema-forge import",
            None,
        )
        .await
        .context("opening the import turn")?;
    match engine.import(cortex.store(), source, design.id.0, turn.id.0).await {
        Ok(report) => {
            let summary = format!("imported {} {} objects", report.version, report.objects);
            // The turn holds the import's operation, so it cannot be rejected: commit it, a lost connection tried
            // again, and if it still cannot be committed remove the design this command made, never leaving it held.
            let mut committed = cortex.commit(&by, &turn, Some(&summary)).await;
            for attempt in 1..3 {
                if committed.is_ok() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(500 * attempt)).await;
                committed = cortex.commit(&by, &turn, Some(&summary)).await;
            }
            let seq = match committed {
                Ok(seq) => seq,
                Err(failure) => {
                    let removed = cortex.delete_design(design.id).await;
                    let failure = anyhow::Error::new(failure).context("committing the import turn");
                    return Err(match removed {
                        Ok(()) => failure.context(format!("the design {name} it made was removed")),
                        Err(e) => failure.context(format!(
                            "and the design {name} ({}) could not be removed, its turn {} still open: {e}",
                            design.id, turn.id
                        )),
                    });
                }
            };
            Ok(Imported {
                design: design.id,
                turn: seq,
                flavor,
                report,
            })
        }
        Err(failure) => {
            let rejected = cortex.reject(&by, &turn).await;
            let failure = anyhow::Error::new(failure).context("the import failed");
            match rejected {
                Ok(()) => Err(failure),
                Err(e) => Err(failure.context(format!("and its turn could not be rejected: {e}"))),
            }
        }
    }
}

fn seconds(d: Duration) -> String {
    format!("{:.2} s", d.as_secs_f64())
}

#[allow(clippy::too_many_arguments)]
async fn import(
    at: Where,
    engine: &str,
    source: &str,
    design: &str,
    flavor: Option<&str>,
    tls: bool,
    connections: usize,
    password_env: Option<&str>,
) -> anyhow::Result<bool> {
    let registry = registry();
    let engine = registry.get(engine).with_context(|| {
        format!(
            "no engine `{engine}` (this binary has: {})",
            registry.ids().collect::<Vec<_>>().join(", ")
        )
    })?;
    let password = match password_env {
        Some(variable) => {
            std::env::var(variable).with_context(|| format!("the environment variable {variable} is not set"))?
        }
        None => String::new(),
    };
    let source = Source {
        url: source.to_string(),
        password,
        tls,
        connections: connections.max(1),
    };
    let cortex = Cortex::new(store_at(&at, false)?);
    let done = import_design(&cortex, engine, &source, design, flavor).await?;
    let r = &done.report;
    println!(
        "pass  import into the design {design} ({}), committed as turn {}",
        done.design, done.turn
    );
    println!("  server     {} {}", r.version, done.flavor);
    println!("  objects    {}", r.objects);
    println!("  rows       {} in {} statements", r.rows, r.statements);
    println!("  read       {}", seconds(r.read));
    println!("  stored     {}", seconds(r.stored));
    Ok(true)
}

async fn write(at: Where, design: &str, tls: bool) -> anyhow::Result<bool> {
    let store = store_at(&at, tls)?;
    let name = design.to_string();
    let (id, engine) = store
        .read(&Account::Service, async |tx| {
            let row = tx
                .query_opt("SELECT id, engine FROM cortex.designs WHERE name = $1", &[&name])
                .await?;
            Ok(row.map(|r| (r.get::<_, uuid::Uuid>(0), r.get::<_, String>(1))))
        })
        .await?
        .with_context(|| format!("no design named {design}"))?;
    let registry = registry();
    let engine = registry
        .get(&engine)
        .with_context(|| format!("the design {design} is of the engine `{engine}`, which this binary does not have"))?;
    print!("{}", engine.write(&store, id).await?);
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use schema_forge_engine::{EngineError, Mapped, Probe};
    use uuid::Uuid;

    /// An engine whose server cannot be read.
    struct Broken;

    #[async_trait]
    impl Engine for Broken {
        fn id(&self) -> &'static str {
            "mysql"
        }
        fn namespace(&self) -> &'static str {
            "engine_mysql"
        }
        async fn probe(&self, _: &Store, _: &Source) -> Result<Probe, EngineError> {
            Ok(Probe {
                version: "8.0".to_string(),
                flavor: "mysql".to_string(),
            })
        }
        async fn import(&self, _: &Store, _: &Source, _: Uuid, _: Uuid) -> Result<ImportReport, EngineError> {
            Err(EngineError::Source("the server went away".to_string()))
        }
        async fn write(&self, _: &Store, _: Uuid) -> Result<String, EngineError> {
            Ok(String::new())
        }
        fn arrow_type(&self, _: &str) -> Mapped {
            Mysql.arrow_type("int")
        }
    }

    fn env(name: &str) -> String {
        std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set: run python3 tools/app/all.py"))
    }

    fn cortex() -> Cortex {
        let endpoint = Endpoint::new(env("SF_TEST_HOST"), env("SF_TEST_PORT").parse().expect("SF_TEST_PORT"));
        let accounts = Accounts::read(std::path::Path::new(&env("SF_TEST_ACCOUNTS"))).expect("the accounts file");
        Cortex::new(Store::new(endpoint, accounts))
    }

    #[tokio::test]
    async fn a_failed_import_leaves_its_turn_rejected_and_the_design_free_for_the_next_turn() {
        let cortex = cortex();
        let name = format!("t_{}", Uuid::now_v7().simple());
        let source = Source {
            url: "mysql://nobody@nowhere".to_string(),
            password: String::new(),
            tls: false,
            connections: 1,
        };
        let failure = import_design(&cortex, &Broken, &source, &name, None).await.unwrap_err();
        assert!(format!("{failure:#}").contains("the server went away"), "{failure:#}");
        let (design, state) = cortex
            .store()
            .read(&Account::Service, async |tx| {
                let row = tx
                    .query_one(
                        "SELECT d.id, t.state FROM cortex.designs d JOIN cortex.turns t ON t.design = d.id WHERE d.name = $1",
                        &[&name],
                    )
                    .await?;
                Ok((row.get::<_, schema_forge_core::DesignId>(0), row.get::<_, String>(1)))
            })
            .await
            .expect("the design and its turn");
        assert_eq!(state, "rejected");
        let main = cortex
            .store()
            .read(&Account::Service, async |tx| {
                Ok(tx
                    .query_one("SELECT id FROM cortex.branches WHERE design = $1", &[&design])
                    .await?
                    .get::<_, schema_forge_core::BranchId>(0))
            })
            .await
            .expect("the main branch");
        cortex
            .open_turn(&Account::Service, design, main, TurnKind::Edit, "test", None)
            .await
            .expect("the design is free for the next turn");
    }
}
