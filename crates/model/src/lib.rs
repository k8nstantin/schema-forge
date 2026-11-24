//! The schema skeleton: what every database has, held the same way for all (docs/engines.xml, "The shared model is a
//! skeleton"). A schema names its engine; namespaces, objects, columns and links carry an engine section that the
//! engine owns and the skeleton stores without reading. Nothing here knows any database.
//!
//! Engines make the parts with their constructors and set the rest by field, so a field added to the model later
//! breaks no engine:
//!
//! ```
//! use schema_forge_model::{Column, Id, Object};
//! let id = |s: &str| Id::try_from(s).expect("an id");
//! let mut orders = Object::new(id("o_orders"), "table", id("n_sales"), "orders");
//! orders.comment = Some("one row per order".into());
//! orders.columns.push(Column::new(id("c_orders_id"), "id", "long", false));
//! ```
//!
//! ```compile_fail
//! use schema_forge_model::{Column, Id};
//! let c = Column { id: Id::try_from("c_x").unwrap(), name: "x".into(), data_type: "long".into(), null: false,
//!                  comment: None, engine: Default::default() };
//! ```

mod check;
mod id;
mod schema;

pub use check::{Problem, check};
pub use id::{Id, IdError, Ids, Kind};
pub use schema::{Area, Column, Ends, EngineRef, FORMAT, Link, Namespace, Object, Schema, Section};
