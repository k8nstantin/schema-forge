//! Where `schema_forge` is: a host (or a Unix socket's folder), a port, the database, and whether TLS is required
//! (decision pg-driver: the same code serves the local cluster over its socket and a team server over TCP and TLS).

use std::sync::Arc;
use std::time::Duration;

use tokio_postgres::config::SslMode;

use crate::StoreError;

/// Whether the connection is encrypted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tls {
    /// No TLS: the local cluster, over its Unix socket or 127.0.0.1.
    Disable,
    /// TLS required, the server's certificate checked against this machine's trusted roots.
    Require,
}

/// Where the store is.
#[derive(Clone, Debug)]
pub struct Endpoint {
    /// A host name or address, or the folder of a Unix socket (it starts with `/`).
    pub host: String,
    /// The port.
    pub port: u16,
    /// The database: `schema_forge`.
    pub database: String,
    /// Whether TLS is required.
    pub tls: Tls,
    /// The name each connection gives the server (`pg_stat_activity.application_name`).
    pub application: String,
    /// The longest a statement may run before the server cancels it (SQLSTATE 57014), so a stuck query never holds a
    /// connection for ever.
    pub statement_timeout: Duration,
}

/// After this long idle, TCP keepalives start probing a connection.
pub const KEEPALIVE_IDLE: Duration = Duration::from_secs(30);
/// Between two keepalive probes.
pub const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(10);
/// Probes unanswered before the connection is dropped: a link that died without a reset is noticed within
/// `KEEPALIVE_IDLE + KEEPALIVE_INTERVAL * KEEPALIVE_RETRIES`.
pub const KEEPALIVE_RETRIES: u32 = 3;

impl Endpoint {
    /// `schema_forge` on a host and port, without TLS.
    #[must_use]
    pub fn new(host: impl Into<String>, port: u16) -> Endpoint {
        Endpoint {
            host: host.into(),
            port,
            database: "schema_forge".into(),
            tls: Tls::Disable,
            application: "schema-forge".into(),
            statement_timeout: Duration::from_mins(1),
        }
    }

    pub(crate) fn config(&self, role: &str, password: &str) -> tokio_postgres::Config {
        let mut config = tokio_postgres::Config::new();
        config
            .host(&self.host)
            .port(self.port)
            .dbname(&self.database)
            .user(role)
            .password(password)
            .application_name(&self.application)
            .connect_timeout(Duration::from_secs(10))
            .keepalives(true)
            .keepalives_idle(KEEPALIVE_IDLE)
            .keepalives_interval(KEEPALIVE_INTERVAL)
            .keepalives_retries(KEEPALIVE_RETRIES)
            .options(format!("-c statement_timeout={}", self.statement_timeout.as_millis()))
            .ssl_mode(match self.tls {
                Tls::Disable => SslMode::Disable,
                Tls::Require => SslMode::Require,
            });
        config
    }

    pub(crate) fn connector() -> Result<tokio_postgres_rustls::MakeRustlsConnect, StoreError> {
        let mut roots = rustls::RootCertStore::empty();
        let found = rustls_native_certs::load_native_certs();
        roots.add_parsable_certificates(found.certs);
        if roots.is_empty() {
            return Err(StoreError::Tls("no trusted root certificate on this machine".into()));
        }
        let config = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .map_err(|e| StoreError::Tls(e.to_string()))?
            .with_root_certificates(roots)
            .with_no_client_auth();
        Ok(tokio_postgres_rustls::MakeRustlsConnect::new(config))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_connection_has_keepalives_and_a_statement_timeout() {
        let mut endpoint = Endpoint::new("127.0.0.1", 5432);
        endpoint.statement_timeout = Duration::from_millis(1500);
        let config = endpoint.config("cortex_reader", "x");
        assert!(config.get_keepalives());
        assert_eq!(config.get_keepalives_idle(), KEEPALIVE_IDLE);
        assert_eq!(config.get_keepalives_interval(), Some(KEEPALIVE_INTERVAL));
        assert_eq!(config.get_keepalives_retries(), Some(KEEPALIVE_RETRIES));
        assert_eq!(config.get_options(), Some("-c statement_timeout=1500"));
    }
}
