//! Reading a schema from a live MySQL (docs/connections.md): the connection's fields, a test in five steps, and a
//! read that sends only statements that read. The read asks the server for each object's definition as it writes it
//! (`SHOW CREATE …`), in the order `mysqldump` writes them, and reads them through the same reader as a dump: a schema
//! read live and one read from a dump of the same database are the same model.

use std::fmt::Write as _;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use mysql::prelude::Queryable;
use mysql::{Conn, OptsBuilder, Row, SslOpts};
use schema_forge_engine::Imported;
use schema_forge_engine::live::{Field, FieldKind, Outcome, Profile, Secret, Step, StepKind};

use crate::read;
use crate::types::Family;
use crate::write::{quote, string};

/// What a connection to MySQL needs, in the order the Connections page shows it.
pub const FIELDS: &[Field] = &[
    Field::new("host", "Host", FieldKind::Text, "The server's name or address").required(),
    Field::new("port", "Port", FieldKind::Number, "Where the server listens").default("3306"),
    Field::new("user", "User", FieldKind::Text, "The account to sign in as; one that can only read is best").required(),
    Field::new("password", "Password", FieldKind::Secret, "The account's password, kept where you choose"),
    Field::new(
        "databases",
        "Databases",
        FieldKind::Text,
        "The databases to read, separated by commas; every one the account can see when empty",
    ),
    Field::new(
        "tls",
        "TLS",
        FieldKind::OneOf(&["verify", "required", "preferred", "off"]),
        "verify: encrypted, and the server's certificate checked; required: encrypted, the certificate not checked; \
         preferred: encrypted when the server can; off: never encrypted",
    )
    .default("verify"),
    Field::new(
        "ca",
        "CA certificate",
        FieldKind::Path,
        "The certificate to check the server's with, when this machine does not trust it",
    ),
    Field::new("timeout", "Timeout", FieldKind::Number, "Seconds to wait for the server").default("10"),
];

/// The databases every server has, which are the server's, never a schema's.
const SYSTEM: &[&str] = &["mysql", "information_schema", "performance_schema", "sys"];

/// What could not be done, and at which step.
struct Failure {
    step: StepKind,
    said: String,
}

/// Tests a connection: reach, secure, sign in, version, rights; stops at the first that fails, the rest skipped.
#[must_use]
pub fn test(profile: &Profile, secret: Option<&Secret>) -> Vec<Step> {
    let mut steps = Vec::new();
    let order = [StepKind::Reach, StepKind::Secure, StepKind::SignIn, StepKind::Version, StepKind::Rights];
    let fail = |steps: &mut Vec<Step>, f: Failure| {
        steps.push(Step::new(f.step, Outcome::Failed, f.said));
        for s in order.iter().skip_while(|s| **s != f.step).skip(1) {
            steps.push(Step::new(*s, Outcome::Skipped, "not tried: a step before it failed"));
        }
    };
    let (host, port, timeout) = match target(profile) {
        Ok(t) => t,
        Err(said) => {
            fail(&mut steps, Failure { step: StepKind::Reach, said });
            return steps;
        }
    };
    if let Err(said) = reach(&host, port, timeout) {
        fail(&mut steps, Failure { step: StepKind::Reach, said });
        return steps;
    }
    steps.push(Step::new(StepKind::Reach, Outcome::Passed, format!("{host}:{port} answers")));
    let mut conn = match connect(profile, secret) {
        Ok(c) => c,
        Err(f) => {
            // MySQL settles TLS before it checks the user: a refused user was refused over the TLS asked for.
            if f.step == StepKind::SignIn {
                let mode = profile.get("tls", FIELDS).unwrap_or("verify");
                steps.push(match mode {
                    "verify" => Step::new(StepKind::Secure, Outcome::Passed, "encrypted, the certificate checked"),
                    "off" => Step::new(StepKind::Secure, Outcome::Warning, "not encrypted, as asked"),
                    _ => Step::new(StepKind::Secure, Outcome::Warning, "encrypted, the certificate not checked"),
                });
            }
            fail(&mut steps, f);
            return steps;
        }
    };
    let tls: Option<String> = conn
        .query_first::<Row, _>("SHOW SESSION STATUS LIKE 'Ssl_version'")
        .ok()
        .flatten()
        .and_then(|r| r.get::<String, _>(1))
        .filter(|v| !v.is_empty());
    let mode = profile.get("tls", FIELDS).unwrap_or("verify");
    steps.push(match (&tls, mode) {
        (Some(v), "verify") => {
            Step::new(StepKind::Secure, Outcome::Passed, format!("encrypted with {v}, the certificate checked"))
        }
        (Some(v), _) => Step::new(
            StepKind::Secure,
            Outcome::Warning,
            format!("encrypted with {v}, but the server's certificate is not checked"),
        ),
        (None, _) => Step::new(
            StepKind::Secure,
            Outcome::Warning,
            "not encrypted: the password and the schema cross the network as they are",
        ),
    });
    let user = profile.get("user", FIELDS).unwrap_or_default();
    steps.push(Step::new(StepKind::SignIn, Outcome::Passed, format!("signed in as {user}")));
    match server_version(&mut conn) {
        Ok(v) => steps.push(Step::new(
            StepKind::Version,
            Outcome::Passed,
            format!("MySQL {v}: a schema read from it is designed for MySQL {}", read::version_for(&v)),
        )),
        Err(said) => {
            fail(&mut steps, Failure { step: StepKind::Version, said });
            return steps;
        }
    }
    steps.push(rights(&mut conn, profile));
    steps
}

/// Reads the schema of the databases `which` names (or the profile's, or every one the account sees).
///
/// # Errors
/// When the connection cannot be made, or the server refuses to give a definition.
pub fn read(
    families: &[Family],
    profile: &Profile,
    secret: Option<&Secret>,
    which: &[String],
) -> Result<Imported, String> {
    let mut conn = connect(profile, secret).map_err(|f| f.said)?;
    let server = server_version(&mut conn)?;
    let version = read::version_for(&server);
    let databases = databases(&mut conn, profile, which)?;
    let mut sql = String::new();
    for (n, db) in databases.iter().enumerate() {
        script(&mut conn, db, n == 0, &mut sql)?;
    }
    Ok(read::read(families, &sql, version))
}

/// One database, as a dump of it would hold it.
fn script(conn: &mut Conn, db: &str, first: bool, sql: &mut String) -> Result<(), String> {
    let q = quote(db);
    // In the database, as mysqldump is, so a view's query names its tables as the database's own, unqualified.
    conn.query_drop(format!("USE {q}")).map_err(|e| e.to_string())?;
    let create: Row = first_row(conn, &format!("SHOW CREATE DATABASE {q}"))?;
    let _ = writeln!(sql, "{};\nUSE {q};", text(&create, 1)?);
    if first {
        server_objects(conn, sql)?;
    }
    let tables: Vec<(String, String)> = conn
        .exec(
            "SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? ORDER BY TABLE_NAME",
            (db,),
        )
        .map_err(|e| e.to_string())?;
    for (table, _) in tables.iter().filter(|(_, kind)| kind == "BASE TABLE") {
        let row: Row = first_row(conn, &format!("SHOW CREATE TABLE {q}.{}", quote(table)))?;
        let _ = writeln!(sql, "{};", text(&row, 1)?);
        let triggers: Vec<String> = conn
            .exec(
                "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA = ? AND \
                 EVENT_OBJECT_TABLE = ? ORDER BY ACTION_ORDER",
                (db, table),
            )
            .map_err(|e| e.to_string())?;
        for t in triggers {
            let row: Row = first_row(conn, &format!("SHOW CREATE TRIGGER {q}.{}", quote(&t)))?;
            program(sql, &row, "SQL Original Statement", None)?;
        }
    }
    let names = |conn: &mut Conn, query: &str| -> Result<Vec<String>, String> {
        conn.exec(query, (db,)).map_err(|e| e.to_string())
    };
    for e in names(conn, "SELECT EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA = ? ORDER BY EVENT_NAME")?
    {
        let row: Row = first_row(conn, &format!("SHOW CREATE EVENT {q}.{}", quote(&e)))?;
        program(sql, &row, "Create Event", Some("time_zone"))?;
    }
    // Libraries, from 9.2, before the routines that import them; a server without them has no such table.
    if let Ok(libraries) = names(
        conn,
        "SELECT LIBRARY_NAME FROM information_schema.LIBRARIES WHERE LIBRARY_SCHEMA = ? ORDER BY LIBRARY_NAME",
    ) {
        for l in libraries {
            let row: Row = first_row(conn, &format!("SHOW CREATE LIBRARY {q}.{}", quote(&l)))?;
            program(sql, &row, "Create Library", None)?;
        }
    }
    for kind in ["FUNCTION", "PROCEDURE"] {
        let query = format!(
            "SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = ? AND ROUTINE_TYPE = '{kind}' \
             ORDER BY ROUTINE_NAME"
        );
        for r in names(conn, &query)? {
            let row: Row = first_row(conn, &format!("SHOW CREATE {kind} {q}.{}", quote(&r)))?;
            let column = if kind == "FUNCTION" { "Create Function" } else { "Create Procedure" };
            if row.get::<Option<String>, _>(column).flatten().is_none() {
                return Err(format!("the account cannot read the body of {kind} {r}: it needs SHOW_ROUTINE"));
            }
            program(sql, &row, column, None)?;
        }
    }
    for (view, _) in tables.iter().filter(|(_, kind)| kind == "VIEW") {
        let row: Row = first_row(conn, &format!("SHOW CREATE VIEW {q}.{}", quote(view)))?;
        let settings =
            [("character_set_client", "character_set_client"), ("collation_connection", "collation_connection")];
        set(sql, &row, &settings)?;
        let _ = writeln!(sql, "{};", text(&row, 1)?);
    }
    Ok(())
}

/// What the server holds beside its databases and a dump leaves out: general tablespaces, and the spatial reference
/// systems people defined (MySQL's own come from the EPSG).
fn server_objects(conn: &mut Conn, sql: &mut String) -> Result<(), String> {
    let spaces: Vec<(String, Option<String>, Option<String>)> = conn
        .query(
            "SELECT t.NAME, f.FILE_NAME, f.ENGINE FROM information_schema.INNODB_TABLESPACES t LEFT JOIN \
             information_schema.FILES f ON f.TABLESPACE_NAME = t.NAME WHERE t.SPACE_TYPE = 'General' ORDER BY t.NAME",
        )
        .map_err(|e| format!("the server's general tablespaces cannot be read (the account needs PROCESS): {e}"))?;
    for (name, file, engine) in spaces {
        let mut t = format!("CREATE TABLESPACE {}", quote(&name));
        if let Some(f) = file {
            // A file in the data directory is named as it was made; one outside it keeps its whole path.
            let f = f.strip_prefix("./").unwrap_or(&f);
            let _ = write!(t, " ADD DATAFILE {}", string(f));
        }
        if let Some(e) = engine {
            let _ = write!(t, " ENGINE={e}");
        }
        let _ = writeln!(sql, "{t};");
    }
    let systems: Vec<Row> = conn
        .query(
            "SELECT SRS_ID, SRS_NAME, DEFINITION, ORGANIZATION, ORGANIZATION_COORDSYS_ID, DESCRIPTION FROM \
             information_schema.ST_SPATIAL_REFERENCE_SYSTEMS WHERE ORGANIZATION IS NULL OR ORGANIZATION <> 'EPSG' \
             ORDER BY SRS_ID",
        )
        .map_err(|e| e.to_string())?;
    for r in systems {
        let id: i64 = r.get(0).ok_or("a spatial reference system without its id")?;
        let mut t = format!(
            "CREATE SPATIAL REFERENCE SYSTEM {id} NAME {} DEFINITION {}",
            string(&text(&r, 1)?),
            string(&text(&r, 2)?)
        );
        if let (Some(Some(org)), Some(Some(org_id))) = (r.get::<Option<String>, _>(3), r.get::<Option<i64>, _>(4)) {
            let _ = write!(t, " ORGANIZATION {} IDENTIFIED BY {org_id}", string(&org));
        }
        if let Some(Some(d)) = r.get::<Option<String>, _>(5) {
            let _ = write!(t, " DESCRIPTION {}", string(&d));
        }
        let _ = writeln!(sql, "{t};");
    }
    Ok(())
}

/// A stored program as a dump writes it: the settings it was made under, then its definition inside `DELIMITER`.
fn program(sql: &mut String, row: &Row, column: &str, zone: Option<&str>) -> Result<(), String> {
    let mut settings = vec![
        ("sql_mode", "sql_mode"),
        ("character_set_client", "character_set_client"),
        ("collation_connection", "collation_connection"),
    ];
    if let Some(z) = zone {
        settings.push(("time_zone", z));
    }
    set(sql, row, &settings)?;
    let definition =
        row.get::<Option<String>, _>(column).flatten().ok_or_else(|| format!("no `{column}` was given"))?;
    let _ = writeln!(sql, "DELIMITER ;;\n{definition} ;;\nDELIMITER ;");
    Ok(())
}

/// `SET name = value, …` for the settings a definition was made under, from the columns of its row.
fn set(sql: &mut String, row: &Row, settings: &[(&str, &str)]) -> Result<(), String> {
    let mut parts = Vec::new();
    for (setting, column) in settings {
        let v = row.get::<Option<String>, _>(*column).flatten().ok_or_else(|| format!("no `{column}` was given"))?;
        parts.push(format!("{setting} = {}", string(&v)));
    }
    let _ = writeln!(sql, "SET {};", parts.join(", "));
    Ok(())
}

fn first_row(conn: &mut Conn, query: &str) -> Result<Row, String> {
    conn.query_first::<Row, _>(query).map_err(|e| e.to_string())?.ok_or_else(|| format!("`{query}` gave nothing"))
}

fn text(row: &Row, at: usize) -> Result<String, String> {
    row.get::<Option<String>, _>(at).flatten().ok_or_else(|| format!("column {at} is empty"))
}

/// The databases to read: those asked for, the profile's, or every one the account sees but the server's own.
fn databases(conn: &mut Conn, profile: &Profile, which: &[String]) -> Result<Vec<String>, String> {
    let named: Vec<String> = if which.is_empty() {
        profile
            .get("databases", FIELDS)
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect()
    } else {
        which.to_vec()
    };
    let seen: Vec<String> = conn
        .query("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME")
        .map_err(|e| e.to_string())?;
    if named.is_empty() {
        return Ok(seen.into_iter().filter(|d| !SYSTEM.contains(&d.as_str())).collect());
    }
    for d in &named {
        if !seen.contains(d) {
            return Err(format!("the account sees no database `{d}`"));
        }
    }
    Ok(named)
}

fn target(profile: &Profile) -> Result<(String, u16, Duration), String> {
    let host = profile.get("host", FIELDS).ok_or("no host is given")?.to_string();
    let port = profile
        .get("port", FIELDS)
        .unwrap_or("3306")
        .parse::<u16>()
        .map_err(|_| "the port is not a port".to_string())?;
    let secs = profile
        .get("timeout", FIELDS)
        .unwrap_or("10")
        .parse::<u64>()
        .map_err(|_| "the timeout is not a number of seconds".to_string())?;
    Ok((host, port, Duration::from_secs(secs)))
}

fn reach(host: &str, port: u16, timeout: Duration) -> Result<(), String> {
    let addrs: Vec<_> = (host, port).to_socket_addrs().map_err(|e| format!("{host} is not found: {e}"))?.collect();
    let mut last = format!("{host} has no address");
    for a in addrs {
        match TcpStream::connect_timeout(&a, timeout) {
            Ok(_) => return Ok(()),
            Err(e) => last = format!("{host}:{port} does not answer: {e}"),
        }
    }
    Err(last)
}

/// Signs in, with TLS as the profile asks.
fn connect(profile: &Profile, secret: Option<&Secret>) -> Result<Conn, Failure> {
    let (host, port, timeout) = target(profile).map_err(|said| Failure { step: StepKind::Reach, said })?;
    let user =
        profile.get("user", FIELDS).ok_or(Failure { step: StepKind::SignIn, said: "no user is given".into() })?;
    let base = OptsBuilder::new()
        .ip_or_hostname(Some(host))
        .tcp_port(port)
        .user(Some(user))
        .pass(secret.map(|s| s.expose().to_string()))
        .tcp_connect_timeout(Some(timeout))
        .read_timeout(Some(Duration::from_secs(60)))
        .prefer_socket(false);
    let mode = profile.get("tls", FIELDS).unwrap_or("verify");
    let lenient = SslOpts::default().with_danger_accept_invalid_certs(true).with_danger_skip_domain_validation(true);
    let ssl = match mode {
        "verify" => {
            let ssl = SslOpts::default();
            Some(match profile.get("ca", FIELDS) {
                Some(ca) => ssl.with_root_cert_path(Some(std::path::PathBuf::from(ca))),
                None => ssl,
            })
        }
        "required" | "preferred" => Some(lenient),
        "off" => None,
        other => return Err(Failure { step: StepKind::Secure, said: format!("`{other}` is not a TLS mode") }),
    };
    match Conn::new(base.clone().ssl_opts(ssl)) {
        Ok(c) => Ok(c),
        Err(e) if mode == "preferred" && tls_failed(&e) => {
            Conn::new(base.ssl_opts(None)).map_err(|e| failure(&e, false))
        }
        Err(e) => Err(failure(&e, mode != "off")),
    }
}

fn tls_failed(e: &mysql::Error) -> bool {
    matches!(e, mysql::Error::TlsError(_) | mysql::Error::DriverError(mysql::DriverError::TlsNotSupported))
}

/// The step a connection failed at, and what the server or the network said.
fn failure(e: &mysql::Error, tls: bool) -> Failure {
    match e {
        e if tls_failed(e) => Failure { step: StepKind::Secure, said: format!("TLS failed: {e}") },
        mysql::Error::MySqlError(m) if m.code == 1045 || m.code == 1044 => {
            Failure { step: StepKind::SignIn, said: format!("the server refused the user: {}", m.message) }
        }
        mysql::Error::IoError(io) if tls => {
            Failure { step: StepKind::Secure, said: format!("the connection broke while securing it: {io}") }
        }
        other => Failure { step: StepKind::SignIn, said: other.to_string() },
    }
}

fn server_version(conn: &mut Conn) -> Result<String, String> {
    conn.query_first::<String, _>("SELECT VERSION()")
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "the server gave no version".to_string())
}

/// Whether the account can read the definitions, and whether it can change anything too.
fn rights(conn: &mut Conn, profile: &Profile) -> Step {
    let grants: Vec<String> = match conn.query("SHOW GRANTS") {
        Ok(g) => g,
        Err(e) => {
            return Step::new(
                StepKind::Rights,
                Outcome::Failed,
                format!("the server would not say the account's rights: {e}"),
            );
        }
    };
    let all = grants.join("\n").to_ascii_uppercase();
    let databases = match databases(conn, profile, &[]) {
        Ok(d) => d,
        Err(e) => return Step::new(StepKind::Rights, Outcome::Failed, e),
    };
    if databases.is_empty() {
        return Step::new(StepKind::Rights, Outcome::Failed, "the account sees no database to read");
    }
    // What reading every definition needs: SHOW CREATE TRIGGER needs TRIGGER, SHOW CREATE EVENT needs EVENT, a
    // routine's body SHOW_ROUTINE, and the server's general tablespaces PROCESS. MySQL has no narrower right for them.
    const NEEDED: &[&str] = &["SELECT", "SHOW VIEW", "TRIGGER", "EVENT", "SHOW_ROUTINE", "PROCESS"];
    let missing: Vec<&str> =
        NEEDED.iter().copied().filter(|n| !all.contains("ALL PRIVILEGES") && !all.contains(n)).collect();
    if !missing.is_empty() {
        return Step::new(
            StepKind::Rights,
            Outcome::Failed,
            format!("the account cannot read every definition: grant it {}", missing.join(", ")),
        );
    }
    const CHANGES: &[&str] =
        &["ALL PRIVILEGES", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER", "GRANT OPTION", "SUPER"];
    let changes: Vec<&str> = CHANGES.iter().copied().filter(|c| all.contains(c)).collect();
    let sees = format!("it sees {}", databases.join(", "));
    if changes.is_empty() {
        Step::new(
            StepKind::Rights,
            Outcome::Passed,
            format!("the account reads definitions and changes nothing; {sees}"),
        )
    } else {
        Step::new(
            StepKind::Rights,
            Outcome::Warning,
            format!(
                "the account can also change things ({}): one that can only read is recommended; {sees}",
                changes.join(", ")
            ),
        )
    }
}
