//! Add-ons: what people add onto this engine without forking it.
//!
//! An add-on is a type implementing [`AddOn`], usually in a crate of its own, registered with one line:
//!
//! ```ignore
//! let engine = schema_forge_mysql::Mysql::new().with(my_addon::Conventions);
//! ```
//!
//! It contributes what a MySQL-compatible system or a company's conventions bring: types now, and statement handlers
//! and rules as the engine opens them. Every part has a default, so an add-on written today keeps building when a part
//! is added.

use crate::types::Family;

/// Something added onto the MySQL engine.
pub trait AddOn: Send + Sync {
    /// Its name, as people say it.
    fn name(&self) -> &'static str;

    /// The types it adds to the catalog, after MySQL's own.
    fn types(&self) -> &[Family] {
        &[]
    }
}
