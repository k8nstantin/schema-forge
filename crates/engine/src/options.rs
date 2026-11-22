//! An engine's options: what it may hold in the `options` of each part of the section layout, declared as data. The
//! section layout is the template every engine shares; its options are each engine's own schema. An option an engine
//! does not declare is refused by the conformance kit, so no engine grows storage nobody described. The declarations
//! are also what the canvas builds its option forms from.
//!
//! ```
//! use schema_forge_engine::options::{OptionKind, OptionSpec, Part};
//! const FILLFACTOR: OptionSpec = OptionSpec::new(Part::Object, "fillfactor", OptionKind::Integer, "How full each page is filled, in percent")
//!     .for_kinds(&["table"]);
//! assert_eq!(FILLFACTOR.key, "fillfactor");
//! ```

use crate::Availability;

/// The part of the section layout an option sits on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Part {
    Schema,
    Namespace,
    /// An object, of the kinds the option names.
    Object,
    Column,
    Key,
    Check,
    Index,
    IndexPart,
    Partitioning,
    PartField,
    Partition,
    Sequence,
    Domain,
    Field,
    Identity,
    Generated,
    Link,
    Deferrable,
    OrderField,
    PartitionOf,
    Kept,
    Routine,
    Parameter,
    Trigger,
    Event,
}

impl Part {
    /// Whether this part belongs to an object, so an option on it may be for some kinds of object only.
    #[must_use]
    pub const fn within_object(self) -> bool {
        !matches!(self, Self::Schema | Self::Namespace | Self::Link | Self::Deferrable | Self::Kept)
    }
}

/// The kind of value an option holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum OptionKind {
    /// True or false.
    Flag,
    /// A whole number.
    Integer,
    /// A number with a fraction (a false-positive rate, a ratio).
    Decimal,
    /// Text.
    Text,
    /// One of these words.
    OneOf(&'static [&'static str]),
    /// Any JSON the engine reads itself (a list of ids, a structure): described by its meaning.
    Json,
}

/// One option an engine may hold: on which part, under which key, of what kind, what it means, in which versions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub struct OptionSpec {
    pub part: Part,
    pub key: &'static str,
    pub kind: OptionKind,
    /// What it means, in a plain sentence, as the person is shown it.
    pub meaning: &'static str,
    /// The kinds of object it applies to, when `part` is an object; empty for every kind.
    pub kinds: &'static [&'static str],
    pub available: Availability,
}

impl OptionSpec {
    /// An option on `part`, for every kind and version.
    #[must_use]
    pub const fn new(part: Part, key: &'static str, kind: OptionKind, meaning: &'static str) -> Self {
        Self { part, key, kind, meaning, kinds: &[], available: Availability::ALWAYS }
    }

    /// The same option, only on objects of these kinds.
    #[must_use]
    pub const fn for_kinds(self, kinds: &'static [&'static str]) -> Self {
        Self { kinds, ..self }
    }

    /// The same option, only in the versions `available` says.
    #[must_use]
    pub const fn available(self, available: Availability) -> Self {
        Self { available, ..self }
    }

    /// The same option, from `version` on.
    #[must_use]
    pub const fn since(self, version: &'static str) -> Self {
        self.available(Availability::since(version))
    }

    /// Whether `value` is a value of this option's kind.
    #[must_use]
    pub fn accepts(&self, value: &serde_json::Value) -> bool {
        match self.kind {
            OptionKind::Flag => value.is_boolean(),
            OptionKind::Integer => value.is_i64() || value.is_u64(),
            OptionKind::Decimal => value.is_number(),
            OptionKind::Text => value.is_string(),
            OptionKind::OneOf(words) => value.as_str().is_some_and(|v| words.contains(&v)),
            OptionKind::Json => true,
        }
    }
}
