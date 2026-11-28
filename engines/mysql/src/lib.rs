//! engine_mysql: MySQL 5.7 to 9.7 and its flavors (Percona Server, Cloud SQL, RDS, Aurora), a plugin like any other.
//! Its schema (engines/mysql/schema) holds what only MySQL has beside the cortex; this crate reads a live server's
//! catalogs, stores what it read as a design's rows and loads them back, and writes a design as SQL.

pub mod catalog;
pub mod keys;
pub mod read;
pub mod show;
