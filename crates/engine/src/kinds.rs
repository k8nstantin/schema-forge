//! An engine's kinds of object, and the slots of the section layout each kind uses: a table its keys and indexes, a
//! view its query, a sequence its sequence. Declared as data, so the kit refuses a slot a kind does not use (a view
//! with partitioning, a table with a query) and the canvas knows each kind by name.
//!
//! ```
//! use schema_forge_engine::kinds::{ObjectKind, Slot};
//! const VIEW: ObjectKind = ObjectKind::new("view", "View", &[Slot::Query]);
//! assert!(VIEW.uses(Slot::Query) && !VIEW.uses(Slot::Indexes));
//! ```

use crate::Availability;

/// A slot of an object's section.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Slot {
    Keys,
    Checks,
    Indexes,
    Partitioning,
    PartitionOf,
    Order,
    Query,
    Sequence,
    Values,
    Domain,
    Fields,
    Routine,
    Trigger,
    Event,
}

/// A kind of object the engine has.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub struct ObjectKind {
    /// As an object of the schema names its kind (`table`, `partitioned_table`).
    pub id: &'static str,
    /// As people say it (`"Partitioned table"`).
    pub name: &'static str,
    /// The slots of the section an object of this kind may fill; its options are declared in the engine's options.
    pub slots: &'static [Slot],
    pub available: Availability,
}

impl ObjectKind {
    /// A kind in every version.
    #[must_use]
    pub const fn new(id: &'static str, name: &'static str, slots: &'static [Slot]) -> Self {
        Self { id, name, slots, available: Availability::ALWAYS }
    }

    /// The same kind, only in the versions `available` says.
    #[must_use]
    pub const fn available(self, available: Availability) -> Self {
        Self { available, ..self }
    }

    /// The same kind, from `version` on.
    #[must_use]
    pub const fn since(self, version: &'static str) -> Self {
        self.available(Availability::since(version))
    }

    /// Whether an object of this kind may fill `slot`.
    #[must_use]
    pub fn uses(&self, slot: Slot) -> bool {
        self.slots.contains(&slot)
    }
}
