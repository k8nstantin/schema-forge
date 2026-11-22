//! Portable types: each engine's types as Apache Arrow's, and back. Arrow's type system is the vocabulary every engine
//! shares, and the one Apache DataFusion speaks: through it, any two engines are compared or converted, and a schema
//! of any engine is planned and checked by the DataFusion layer, without a map written for each pair.
//!
//! An engine says how faithful each mapping is. An [`Fidelity::Exact`] mapping comes back as the same type; the
//! conformance kit holds it to that.

pub use arrow_schema::DataType as ArrowType;

use crate::TypeError;

/// How faithfully a type survives the mapping.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum Fidelity {
    /// The same type: mapped back, it is what it was.
    Exact,
    /// The same kind of value, with a detail the other side does not keep (a length, a precision, a zone).
    Approximate,
    /// No type on the other side holds it: the nearest is given, and something is lost.
    Lost,
}

/// A type mapped to the other side, how faithfully, and what is not kept, in words.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct Mapped<T> {
    pub to: T,
    pub fidelity: Fidelity,
    /// What does not survive, when something does not (`"the length 200"`).
    pub lost: Option<String>,
}

impl<T> Mapped<T> {
    /// A mapping that keeps everything.
    #[must_use]
    pub const fn exact(to: T) -> Self {
        Self { to, fidelity: Fidelity::Exact, lost: None }
    }

    /// A mapping that keeps the kind of value but not `lost`.
    #[must_use]
    pub fn approximate(to: T, lost: impl Into<String>) -> Self {
        Self { to, fidelity: Fidelity::Approximate, lost: Some(lost.into()) }
    }

    /// The nearest there is, with `lost` gone.
    #[must_use]
    pub fn lost(to: T, lost: impl Into<String>) -> Self {
        Self { to, fidelity: Fidelity::Lost, lost: Some(lost.into()) }
    }
}

/// An engine's types as Arrow's, and back.
pub trait Portable: Send + Sync {
    /// A column's type, as a schema at `version` holds it, as an Arrow type.
    ///
    /// # Errors
    /// When the text is not one of the engine's types in `version`.
    fn arrow_type(&self, type_text: &str, version: &str) -> Result<Mapped<ArrowType>, TypeError>;

    /// The engine's type for an Arrow type, written as a column of a schema at `version` holds it.
    fn engine_type(&self, arrow: &ArrowType, version: &str) -> Mapped<String>;
}
