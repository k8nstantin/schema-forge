//! PostgreSQL: reading `pg_dump` output (and hand-written DDL) into the model, losing nothing.
//!
//! What the model describes becomes the model; every other statement is kept verbatim, in its place; data is
//! left out and counted. A statement the model cannot fully describe is kept whole, never half-read.

mod read;
pub mod types;
mod write;

pub use read::import;
pub use write::{definition, generate};
