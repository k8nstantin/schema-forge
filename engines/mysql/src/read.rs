//! The read of a live server: gentle and fast. One pool of read-only connections (the source's `connections`, four by
//! default; one is the gentlest), each with a short lock wait and a ceiling on how long a statement may run. The server's
//! version and flavor are read first; then the catalogs, one query per source, together; then `SHOW CREATE` only for what
//! the catalogs do not give, as many at once as the pool has connections.

use std::collections::HashMap;

use futures_util::{StreamExt, TryStreamExt, stream};
use mysql_async::prelude::Queryable;
use mysql_async::{Opts, OptsBuilder, Pool, PoolConstraints, PoolOpts, Row, SslOpts};
use schema_forge_engine::{EngineError, Probe, Source};

use crate::catalog::{Capabilities, Catalog, source_error};
use crate::keys::{AccountName, Kind, ObjectKey, account_literal, q};
use crate::show::{RoutineShow, TableShow, UserShow, ViewShow, parse_routine, parse_table, parse_user, parse_view};

/// How long a statement waits for a lock before giving up, in seconds.
const LOCK_WAIT_SECONDS: u32 = 5;
/// How long a statement may run on the source server, in milliseconds.
const MAX_EXECUTION_MILLIS: u32 = 10_000;

// --- the connection ------------------------------------------------------------------------------------------------------------

/// Where a source is: user, host and port of `mysql://user@host:port`.
fn parse_url(url: &str) -> Result<(String, String, u16), EngineError> {
    let rest = url
        .strip_prefix("mysql://")
        .ok_or_else(|| EngineError::Source(format!("the source `{url}` is not a mysql:// address")))?;
    let (user, host_port) = rest.rsplit_once('@').unwrap_or(("", rest));
    let (host, port) = match host_port.rsplit_once(':') {
        Some((host, port)) => (
            host,
            port.parse::<u16>()
                .map_err(|_| EngineError::Source(format!("the port `{port}` of the source is not a number")))?,
        ),
        None => (host_port, 3306),
    };
    if host.is_empty() {
        return Err(EngineError::Source(format!("the source `{url}` names no host")));
    }
    Ok((user.to_string(), host.to_string(), port))
}

/// A pool of read-only connections to the source, never more than `source.connections`.
pub fn connect(source: &Source) -> Result<Pool, EngineError> {
    let (user, host, port) = parse_url(&source.url)?;
    let connections = source.connections.max(1);
    let constraints = PoolConstraints::new(1, connections)
        .ok_or_else(|| EngineError::Source("the pool of connections is empty".to_string()))?;
    let init = vec![
        "SET SESSION TRANSACTION READ ONLY".to_string(),
        format!("SET SESSION lock_wait_timeout = {LOCK_WAIT_SECONDS}"),
        format!("SET SESSION max_execution_time = {MAX_EXECUTION_MILLIS}"),
        "SET SESSION sql_mode = ''".to_string(),
        "SET NAMES utf8mb4".to_string(),
    ];
    let builder = OptsBuilder::default()
        .user(Some(user))
        .pass((!source.password.is_empty()).then(|| source.password.clone()))
        .ip_or_hostname(host)
        .tcp_port(port)
        .prefer_socket(false)
        .ssl_opts(source.tls.then(SslOpts::default))
        .init(init)
        .pool_opts(PoolOpts::default().with_constraints(constraints));
    Ok(Pool::new(Opts::from(builder)))
}

// --- what the server is --------------------------------------------------------------------------------------------------------

/// The version an engine names (`8.0`) from the server's `@@version` (`8.0.36-28`).
#[must_use]
pub fn engine_version(full: &str) -> Option<String> {
    let mut parts = full.split(|c: char| !c.is_ascii_digit());
    let (major, minor) = (parts.next()?, parts.next()?);
    (!major.is_empty() && !minor.is_empty()).then(|| format!("{major}.{minor}"))
}

/// The flavor an engine names, from the server's `@@version_comment`: Percona Server says so, anything else is MySQL.
#[must_use]
pub fn flavor_of(comment: &str) -> &'static str {
    if comment.to_lowercase().contains("percona") {
        "percona"
    } else {
        "mysql"
    }
}

/// What a server says of itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    /// `@@version`, as written.
    pub full: String,
    /// The version and flavor a design of it is made for.
    pub probe: Probe,
}

/// Reads the server's version and flavor.
pub async fn identify(pool: &Pool) -> Result<Identity, EngineError> {
    let mut conn = pool.get_conn().await.map_err(source_error)?;
    let row: Option<(String, Option<String>)> = conn
        .query_first("SELECT @@version, @@version_comment")
        .await
        .map_err(source_error)?;
    let (full, comment) = row.ok_or_else(|| EngineError::Source("the server did not say its version".to_string()))?;
    let version = engine_version(&full)
        .ok_or_else(|| EngineError::Source(format!("the server's version `{full}` is not a version")))?;
    Ok(Identity {
        probe: Probe {
            version,
            flavor: flavor_of(&comment.unwrap_or_default()).to_string(),
        },
        full,
    })
}

// --- SHOW CREATE ---------------------------------------------------------------------------------------------------------------

/// What `SHOW CREATE` said of each object that needs it, by the object's typed name.
#[derive(Clone, Debug, Default)]
pub struct Shows {
    /// Each table.
    pub tables: HashMap<ObjectKey, TableShow>,
    /// Each view.
    pub views: HashMap<ObjectKey, ViewShow>,
    /// Each procedure and function.
    pub routines: HashMap<ObjectKey, RoutineShow>,
    /// Each account and role.
    pub users: HashMap<AccountName, UserShow>,
}

/// One `SHOW CREATE` to send: what it is for, the statement, and which column of its row holds the text.
struct Job {
    key: ObjectKey,
    sql: String,
    column: usize,
}

/// Sends every job, as many at once as the pool allows, and gives each one's text.
async fn texts(pool: &Pool, jobs: Vec<Job>, at_once: usize) -> Result<Vec<(ObjectKey, String)>, EngineError> {
    stream::iter(jobs)
        .map(|job| async move {
            let mut conn = pool.get_conn().await.map_err(source_error)?;
            let row: Option<Row> = conn
                .query_first(job.sql.as_str())
                .await
                .map_err(|e| EngineError::Source(format!("{}: {e}", job.sql)))?;
            let mut row = row.ok_or_else(|| EngineError::Source(format!("{}: no row", job.sql)))?;
            let text = row
                .take_opt::<Option<String>, _>(job.column)
                .and_then(Result::ok)
                .flatten()
                .ok_or_else(|| {
                    EngineError::Source(format!(
                        "{}: the server gave no text (the account may lack the privilege to see it)",
                        job.sql
                    ))
                })?;
            Ok::<_, EngineError>((job.key, text))
        })
        .buffer_unordered(at_once.max(1))
        .try_collect()
        .await
}

fn show_job(kind: Kind, database: &str, name: &str, statement: &str, column: usize) -> Job {
    Job {
        key: ObjectKey::in_database(database, kind, name),
        sql: format!("SHOW CREATE {statement} {}.{}", q(database), q(name)),
        column,
    }
}

impl Shows {
    /// Reads what the catalogs leave out of the tables, views, routines and accounts they list.
    pub async fn read(pool: &Pool, catalog: &Catalog, at_once: usize) -> Result<Shows, EngineError> {
        let mut jobs = Vec::new();
        for t in &catalog.tables {
            jobs.push(show_job(Kind::Table, &t.table_schema, &t.table_name, "TABLE", 1));
        }
        for v in &catalog.views {
            jobs.push(show_job(Kind::View, &v.table_schema, &v.table_name, "VIEW", 1));
        }
        for r in &catalog.routines {
            let (kind, statement) = if r.routine_type == "FUNCTION" {
                (Kind::Function, "FUNCTION")
            } else {
                (Kind::Procedure, "PROCEDURE")
            };
            jobs.push(show_job(kind, &r.routine_schema, &r.routine_name, statement, 2));
        }
        let accounts: Vec<AccountName> = catalog
            .accounts
            .iter()
            .map(|a| AccountName::new(&a.user, &a.host))
            .collect();
        let account_jobs = accounts.iter().map(|a| Job {
            key: ObjectKey::of_server(Kind::Account, &a.object_name()),
            sql: format!("SHOW CREATE USER {}", account_literal(a)),
            column: 0,
        });
        jobs.extend(account_jobs);
        let mut shows = Shows::default();
        for (key, text) in texts(pool, jobs, at_once).await? {
            let name = key.name.clone();
            match key.kind {
                Kind::Table => {
                    shows.tables.insert(key, parse_table(&text));
                }
                Kind::View => {
                    let database = key.database().unwrap_or_default().to_string();
                    let view = parse_view(&text, &database)
                        .map_err(|e| EngineError::Source(format!("SHOW CREATE VIEW {name}: {e}")))?;
                    shows.views.insert(key, view);
                }
                Kind::Procedure | Kind::Function => {
                    let statement = if key.kind == Kind::Function {
                        "FUNCTION"
                    } else {
                        "PROCEDURE"
                    };
                    let routine = parse_routine(&text, statement, &name)
                        .map_err(|e| EngineError::Source(format!("SHOW CREATE {statement} {name}: {e}")))?;
                    shows.routines.insert(key, routine);
                }
                _ => {
                    shows
                        .users
                        .insert(AccountName::from_object_name(&name), parse_user(&text));
                }
            }
        }
        Ok(shows)
    }
}

// --- the whole read ----------------------------------------------------------------------------------------------------------

/// Everything read from a live server.
#[derive(Clone, Debug)]
pub struct Snapshot {
    /// What the server is.
    pub identity: Identity,
    /// What its catalogs hold.
    pub catalog: Catalog,
    /// What `SHOW CREATE` added.
    pub shows: Shows,
}

/// Reads a server whole: identity, the catalogs together, then the `SHOW CREATE`s.
pub async fn snapshot(pool: &Pool, at_once: usize) -> Result<Snapshot, EngineError> {
    let identity = identify(pool).await?;
    let caps = Capabilities::probe(pool).await?;
    let catalog = Catalog::read(pool, &caps).await?;
    let shows = Shows::read(pool, &catalog, at_once).await?;
    Ok(Snapshot {
        identity,
        catalog,
        shows,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_source_address_gives_its_user_host_and_port() {
        assert_eq!(
            parse_url("mysql://reader@db.example:3307").unwrap(),
            ("reader".into(), "db.example".into(), 3307)
        );
        assert_eq!(
            parse_url("mysql://127.0.0.1").unwrap(),
            ("".into(), "127.0.0.1".into(), 3306)
        );
        assert!(parse_url("postgres://x@y").is_err());
        assert!(parse_url("mysql://x@y:port").is_err());
    }

    #[test]
    fn the_engine_version_is_the_servers_major_and_minor() {
        assert_eq!(engine_version("8.0.36-28").as_deref(), Some("8.0"));
        assert_eq!(engine_version("5.7.44-log").as_deref(), Some("5.7"));
        assert_eq!(engine_version("9.7.0").as_deref(), Some("9.7"));
        assert_eq!(engine_version("garbage"), None);
    }

    #[test]
    fn only_percona_says_it_is_percona() {
        assert_eq!(flavor_of("Percona Server (GPL), Release 28, Revision abc"), "percona");
        assert_eq!(flavor_of("MySQL Community Server - GPL"), "mysql");
    }
}
