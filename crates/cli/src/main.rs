//! `schema-forge`, the one binary. Its first command, `check`, signs in to `schema_forge` as every account in the
//! accounts file and reports what each is and sees; it changes nothing.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
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

#[derive(Subcommand)]
enum Command {
    /// Signs in to `schema_forge` as every account in the accounts file and reports; changes nothing.
    Check {
        /// The store's host, or the folder of its Unix socket.
        #[arg(long, default_value = "127.0.0.1")]
        host: String,
        /// The store's port.
        #[arg(long, default_value_t = 5432)]
        port: u16,
        /// The accounts file the installer wrote (mode 600).
        #[arg(long, default_value = "~/schema-forge-lab-private/local-accounts.env")]
        accounts_file: String,
        /// Require TLS.
        #[arg(long)]
        tls: bool,
    },
}

#[tokio::main]
async fn main() -> ExitCode {
    match Cli::parse().command {
        Command::Check {
            host,
            port,
            accounts_file,
            tls,
        } => match check(host, port, &accounts_file, tls).await {
            Ok(true) => ExitCode::SUCCESS,
            Ok(false) => ExitCode::FAILURE,
            Err(e) => {
                println!("FAIL  {e:#}");
                ExitCode::FAILURE
            }
        },
    }
}

fn expand(path: &str) -> PathBuf {
    match (path.strip_prefix("~/"), std::env::var_os("HOME")) {
        (Some(rest), Some(home)) => PathBuf::from(home).join(rest),
        _ => PathBuf::from(path),
    }
}

/// Each account signs in, and says who it is, the server's version, the cortex's version (the cortex's accounts; a
/// plugin's may not read the plugs, by least privilege) and how many designs it sees (a plugin's, its own engine's
/// alone). True when every account did.
async fn check(host: String, port: u16, accounts_file: &str, tls: bool) -> anyhow::Result<bool> {
    let accounts = Accounts::read(&expand(accounts_file))?;
    let mut endpoint = Endpoint::new(host, port);
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
