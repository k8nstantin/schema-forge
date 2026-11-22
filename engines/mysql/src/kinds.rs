//! Every kind of object MySQL has, and the slots of the section layout each uses. What belongs to the server rather
//! than a schema (accounts, roles, grants, resource groups, servers) is kept as written and counted, not a kind.

use schema_forge_engine::kinds::{ObjectKind, Slot};

use crate::versions;

pub const TABLE: &str = "table";
pub const VIEW: &str = "view";
pub const PROCEDURE: &str = "procedure";
pub const FUNCTION: &str = "function";
pub const LOADABLE_FUNCTION: &str = "loadable_function";
pub const LIBRARY: &str = "library";
pub const TRIGGER: &str = "trigger";
pub const EVENT: &str = "event";
pub const TABLESPACE: &str = "tablespace";
pub const SPATIAL_REFERENCE_SYSTEM: &str = "spatial_reference_system";

pub const KINDS: &[ObjectKind] = &[
    ObjectKind::new(TABLE, "Table", &[Slot::Keys, Slot::Checks, Slot::Indexes, Slot::Partitioning]),
    ObjectKind::new(VIEW, "View", &[Slot::Query]),
    ObjectKind::new(PROCEDURE, "Procedure", &[Slot::Routine]),
    ObjectKind::new(FUNCTION, "Function", &[Slot::Routine]),
    ObjectKind::new(LOADABLE_FUNCTION, "Loadable function", &[]),
    ObjectKind::new(LIBRARY, "Library", &[Slot::Routine]).available(versions::LIBRARIES.available),
    ObjectKind::new(TRIGGER, "Trigger", &[Slot::Trigger]),
    ObjectKind::new(EVENT, "Event", &[Slot::Event]),
    ObjectKind::new(TABLESPACE, "Tablespace", &[]),
    ObjectKind::new(SPATIAL_REFERENCE_SYSTEM, "Spatial reference system", &[]),
];
