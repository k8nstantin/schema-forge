//! Typed ids: a design's id cannot be passed where a turn's is wanted. Every id is a `UUIDv7` the database makes with its
//! row (decision uuidv7-everywhere); the app never makes one.

use std::fmt;

use uuid::Uuid;

macro_rules! id {
    ($name:ident, $what:literal) => {
        #[doc = $what]
        #[derive(
            Clone,
            Copy,
            Debug,
            PartialEq,
            Eq,
            Hash,
            PartialOrd,
            Ord,
            serde::Serialize,
            serde::Deserialize,
            postgres_types::ToSql,
            postgres_types::FromSql,
        )]
        #[postgres(transparent)]
        #[serde(transparent)]
        pub struct $name(pub Uuid);

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(f)
            }
        }
    };
}

id!(DesignId, "A design's id.");
id!(BranchId, "A branch's id.");
id!(TurnId, "A turn's id.");
id!(OperationId, "An operation's id.");
id!(LockedVersionId, "A locked version's id.");
