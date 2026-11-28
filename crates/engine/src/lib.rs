//! The engine interface: what every engine plugin implements, and the registry of the engines the binary ships.
//! Core, the server and the canvas see an engine only through this trait: they never name one, and nothing crosses it
//! as untyped data. An engine reads a live server into a design's rows and writes a design back as SQL; it is a plugin
//! like any other, with its own tables, its own service account and its own crate.

use std::fmt;
use std::time::Duration;

use arrow_schema::DataType;
use async_trait::async_trait;
use schema_forge_store::{Store, StoreError};
use uuid::Uuid;

/// What can go wrong in an engine.
#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    /// The live server could not be reached or read, or refused what was asked of it.
    #[error("the source server: {0}")]
    Source(String),
    /// The store refused or failed.
    #[error(transparent)]
    Store(#[from] StoreError),
    /// The engine cannot do what was asked: a version it does not declare, an object it has no place for.
    #[error("unsupported: {0}")]
    Unsupported(String),
}

/// A live server to read.
#[derive(Clone)]
pub struct Source {
    /// Where it is and who signs in, without the password: `mysql://user@host:port`.
    pub url: String,
    /// The password, kept apart so it is never printed; empty for none.
    pub password: String,
    /// Whether TLS is required, the server's certificate checked against the web's trusted roots.
    pub tls: bool,
    /// How many connections the read may open at once, at least 1.
    pub connections: usize,
}

impl fmt::Debug for Source {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Source")
            .field("url", &self.url)
            .field("password", &"***")
            .field("tls", &self.tls)
            .field("connections", &self.connections)
            .finish()
    }
}

/// What a server is, read before anything of it is stored: the version and flavor a design of it is made for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Probe {
    /// The engine's version as `cortex.engine_versions` names it (`8.0`).
    pub version: String,
    /// The engine's flavor as `cortex.engine_flavors` names it (`mysql`, `percona`).
    pub flavor: String,
}

/// What an import did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportReport {
    /// The design's version, as read.
    pub version: String,
    /// The design's flavor, as read.
    pub flavor: String,
    /// How many objects were stored.
    pub objects: usize,
    /// How many rows were stored in all.
    pub rows: usize,
    /// How many statements were sent to the store, the operation's own among them.
    pub statements: usize,
    /// How long the read of the server took.
    pub read: Duration,
    /// How long storing took.
    pub stored: Duration,
}

/// How faithfully an engine's type maps to an Arrow type.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Fidelity {
    /// It comes back as the same type.
    Exact,
    /// The kind of value is kept; a detail is not (which, in words).
    Approximate(String),
    /// Nothing in Arrow holds it (what is lost, in words).
    Lost(String),
}

/// An engine's type as Apache Arrow's: the one place engines meet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mapped {
    /// The Arrow type.
    pub data_type: DataType,
    /// How faithful it is.
    pub fidelity: Fidelity,
}

/// What every engine plugin implements.
#[async_trait]
pub trait Engine: Send + Sync {
    /// The engine's id in `cortex.engines` (`mysql`).
    fn id(&self) -> &'static str;

    /// The plugin's namespace in the store (`engine_mysql`), whose service account writes its rows.
    fn namespace(&self) -> &'static str;

    /// Reads what a live server is, before a design of it exists: the version and flavor to make the design for. A
    /// version the engine does not declare is refused, naming the server's version and the declared ones (read from
    /// `cortex.engine_versions` in the store, which is why the store is given).
    async fn probe(&self, store: &Store, source: &Source) -> Result<Probe, EngineError>;

    /// Reads the server first, holding no transaction in the store, then writes every row in one operation of the
    /// given open turn, as the plugin's own account, through the store's write and its operation.
    async fn import(
        &self,
        store: &Store,
        source: &Source,
        design: Uuid,
        turn: Uuid,
    ) -> Result<ImportReport, EngineError>;

    /// Loads the design's rows as the plugin's account and returns the SQL a server of the design's version loads.
    async fn write(&self, store: &Store, design: Uuid) -> Result<String, EngineError>;

    /// A column type of this engine as an Arrow type.
    fn arrow_type(&self, column_type: &str) -> Mapped;
}

/// The engines this binary ships, by id.
#[derive(Default)]
pub struct Registry {
    engines: Vec<Box<dyn Engine>>,
}

impl Registry {
    /// An empty registry.
    #[must_use]
    pub fn new() -> Registry {
        Registry::default()
    }

    /// Adds an engine. A second engine of one id is ignored: the first stays.
    #[must_use]
    pub fn with(mut self, engine: Box<dyn Engine>) -> Registry {
        if self.get(engine.id()).is_none() {
            self.engines.push(engine);
        }
        self
    }

    /// The engine of an id.
    #[must_use]
    pub fn get(&self, id: &str) -> Option<&dyn Engine> {
        self.engines.iter().find(|e| e.id() == id).map(AsRef::as_ref)
    }

    /// Every engine's id, in the order added.
    pub fn ids(&self) -> impl Iterator<Item = &'static str> + '_ {
        self.engines.iter().map(|e| e.id())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An engine that does nothing, to fill the registry.
    struct Idle(&'static str);

    #[async_trait]
    impl Engine for Idle {
        fn id(&self) -> &'static str {
            self.0
        }
        fn namespace(&self) -> &'static str {
            "engine_idle"
        }
        async fn probe(&self, _: &Store, _: &Source) -> Result<Probe, EngineError> {
            Err(EngineError::Unsupported("idle".into()))
        }
        async fn import(&self, _: &Store, _: &Source, _: Uuid, _: Uuid) -> Result<ImportReport, EngineError> {
            Err(EngineError::Unsupported("idle".into()))
        }
        async fn write(&self, _: &Store, _: Uuid) -> Result<String, EngineError> {
            Err(EngineError::Unsupported("idle".into()))
        }
        fn arrow_type(&self, _: &str) -> Mapped {
            Mapped {
                data_type: DataType::Utf8,
                fidelity: Fidelity::Exact,
            }
        }
    }

    #[test]
    fn the_registry_finds_each_engine_by_its_id_once() {
        let registry = Registry::new()
            .with(Box::new(Idle("a")))
            .with(Box::new(Idle("b")))
            .with(Box::new(Idle("a")));
        assert_eq!(registry.ids().collect::<Vec<_>>(), vec!["a", "b"]);
        assert_eq!(registry.get("b").map(Engine::namespace), Some("engine_idle"));
        assert!(registry.get("c").is_none());
    }

    #[test]
    fn a_sources_debug_never_shows_its_password() {
        let source = Source {
            url: "mysql://root@127.0.0.1:3306".into(),
            password: "hunter2".into(),
            tls: false,
            connections: 4,
        };
        let shown = format!("{source:?}");
        assert!(!shown.contains("hunter2"));
        assert!(shown.contains("mysql://root@127.0.0.1:3306"));
    }
}
