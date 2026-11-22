//! The schema skeleton: what every database has, held the same way for all (docs/engines.md, "The shared model is a
//! skeleton"). A schema names its engine; namespaces, objects, columns and links carry an engine section that the
//! engine owns and the skeleton stores without reading. Nothing here knows any database.

mod check;
mod id;
mod schema;

pub use check::{Problem, check};
pub use id::{Id, IdError, Ids, Kind};
pub use schema::{Area, Column, Ends, EngineRef, FORMAT, Link, Namespace, Object, Schema, Section};
