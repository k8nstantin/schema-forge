//! engine_mysql: MySQL 5.7 to 9.7 and its flavors (Percona Server, Cloud SQL, RDS, Aurora), a plugin like any other.
//! Its schema (engines/mysql/schema) holds what only MySQL has beside the cortex; this crate reads a live server's
//! catalogs, stores what it read as a design's rows and loads them back, and writes a design as SQL.

pub mod build;
pub mod catalog;
pub mod keys;
pub mod load;
pub mod read;
pub mod rows;
pub mod show;
pub mod sql;
pub mod store;
pub mod types;

use async_trait::async_trait;
use schema_forge_engine::{Engine, EngineError, ImportReport, Mapped, Probe, Source};
use schema_forge_store::Store;
use uuid::Uuid;

/// The MySQL engine, for the registry of the binary.
#[derive(Clone, Copy, Debug, Default)]
pub struct Mysql;

#[async_trait]
impl Engine for Mysql {
    fn id(&self) -> &'static str {
        "mysql"
    }

    fn namespace(&self) -> &'static str {
        "engine_mysql"
    }

    async fn probe(&self, store: &Store, source: &Source) -> Result<Probe, EngineError> {
        let pool = read::connect(source)?;
        let identity = read::identify(&pool).await;
        // The connections are closed whatever the server said.
        let _ = pool.disconnect().await;
        let identity = identity?;
        let declared: Vec<String> = store
            .read(&store::account(), async |tx| {
                let rows = tx
                    .query(
                        "SELECT version FROM cortex.engine_versions WHERE engine = 'mysql' ORDER BY position",
                        &[],
                    )
                    .await?;
                Ok(rows.iter().map(|row| row.get::<_, String>(0)).collect())
            })
            .await?;
        if !declared.contains(&identity.probe.version) {
            return Err(EngineError::Unsupported(format!(
                "the server's version {} is not one engine_mysql declares (it declares {})",
                identity.full,
                declared.join(", ")
            )));
        }
        Ok(identity.probe)
    }

    async fn import(
        &self,
        store: &Store,
        source: &Source,
        design: Uuid,
        turn: Uuid,
    ) -> Result<ImportReport, EngineError> {
        // A version not declared is refused before anything else is read.
        self.probe(store, source).await?;
        store::import(store, source, design, turn).await
    }

    async fn write(&self, store: &Store, design: Uuid) -> Result<String, EngineError> {
        let loaded = load::load(store, design).await?;
        sql::write(&loaded)
    }

    fn arrow_type(&self, column_type: &str) -> Mapped {
        types::arrow_type(column_type)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plugin_names_itself_and_its_namespace() {
        assert_eq!(Mysql.id(), "mysql");
        assert_eq!(Mysql.namespace(), "engine_mysql");
        assert_eq!(Mysql.arrow_type("int").data_type, arrow_schema::DataType::Int32);
    }
}
