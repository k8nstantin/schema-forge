//! The schema model, its readable ids, its own rules and its content hash: the one structure every part of
//! Schema Forge works on (docs/model.md).

mod datatype;
mod hash;
mod id;
mod model;
pub mod types;
mod validate;

pub use datatype::{DataType, StructField};
pub use hash::{canonical, hash};
pub use id::{BadId, Id, Kind};
pub use model::*;
pub use validate::{Problem, check};
