//! Reading and writing the targets' own SQL: PostgreSQL dumps and Iceberg DDL in, the same formats out.

pub mod cursor;
pub mod postgres;
pub mod report;
pub mod split;

pub use report::{Imported, Report};
