//! Iceberg in Spark SQL: reading table and view DDL (one file, or a folder laid out
//! `<catalog>/<namespace>/<table>.sql`), and writing it back.

mod read;
pub mod types;
mod write;

pub use read::{Error, import, import_folder};
pub use write::{definition, generate};
