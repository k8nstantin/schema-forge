//! The engine plugin interface (docs/engines.md). Every database Schema Forge designs for is an engine: a crate that
//! implements [`Engine`] and is registered in a [`Registry`]. The shared code asks the schema's engine; it never names
//! a database itself.
//!
//! An engine starts with its identity, versions and types, and adds the parts its database has. Every part beyond
//! those is optional and has a default, so a part added to this interface later never breaks an engine written before
//! it. Each part is added to the interface when something first uses it, shaped by that use.
//!
//! The conformance kit ([`kit`]) tells an engine's author when it is complete and correct.

pub mod kit;
mod read;
mod registry;
mod types;
mod version;

pub use read::{Imported, Input, Read, Report};
pub use registry::Registry;
pub use types::{Parsed, TypeGroup, TypeSpec, Types};
pub use version::{Availability, Version};

use schema_forge_model::{Id, Problem, Schema};

/// A database Schema Forge designs for.
pub trait Engine: Send + Sync {
    /// Its id in the registry and in every schema designed for it: lowercase, short, stable (`"example"`).
    fn id(&self) -> &'static str;

    /// Its name as people say it (`"Example DB"`).
    fn name(&self) -> &'static str;

    /// Its versions, oldest first. Every feature says the version it came in, and a schema gets the features of its
    /// version.
    fn versions(&self) -> &[Version];

    /// The version a new schema starts at; the newest unless the engine says otherwise.
    fn default_version(&self) -> &'static str {
        self.versions().last().map_or("", |v| v.id)
    }

    /// Its types.
    fn types(&self) -> &dyn Types;

    /// Reading its files (dumps, definition files, table metadata) into a schema.
    fn read(&self) -> Option<&dyn Read> {
        None
    }

    /// Writing a schema as its SQL.
    fn write(&self) -> Option<&dyn Write> {
        None
    }

    /// What a query in its SQL reads, for views.
    fn queries(&self) -> Option<&dyn Queries> {
        None
    }

    /// What makes a schema wrong for it, beyond the model's own checks.
    fn checks(&self) -> Option<&dyn Checks> {
        None
    }
}

/// Writing a schema as the engine's SQL.
pub trait Write: Send + Sync {
    /// One object's definition, or `None` when the schema has no object `id`.
    fn definition(&self, schema: &Schema, id: &Id) -> Option<String>;

    /// The whole schema, in an order the database accepts.
    fn schema(&self, schema: &Schema) -> String;
}

/// Reading queries written in the engine's SQL.
pub trait Queries: Send + Sync {
    /// The tables and views `query` reads, each as the name parts written (`sales.orders` is `["sales", "orders"]`),
    /// in the order first named.
    ///
    /// # Errors
    /// When `query` is not one query in the engine's SQL.
    fn reads(&self, query: &str) -> Result<Vec<Vec<String>>, String>;
}

/// The engine's own checks of a schema.
pub trait Checks: Send + Sync {
    /// Everything that makes `schema` wrong for this engine at its version; none when it is right.
    fn check(&self, schema: &Schema) -> Vec<Problem>;
}
