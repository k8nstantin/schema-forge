//! An engine's types: what the palette shows, what a column may be, and how a type is written.

use std::fmt;

use crate::Availability;

/// A group of types in the palette, in the order the engine lists them (whole numbers, exact decimals, text…).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TypeGroup {
    pub id: &'static str,
    pub title: &'static str,
}

/// One type, or one family of types that take parameters (`decimal(P,S)`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TypeSpec {
    /// Its name as the engine writes it, parameters as letters (`decimal(P,S)`, `varchar(N)`).
    pub name: &'static str,
    /// The group it is shown in.
    pub group: &'static str,
    /// What it holds, in a plain sentence (`"An exact number with P digits, S after the point"`).
    pub meaning: &'static str,
    /// A real type of this family as a column would have it, written exactly as the engine writes it
    /// (`decimal(18,2)`): reading it gives back the same text.
    pub example: &'static str,
    pub available: Availability,
}

/// A type read from text: which family it is, and how the engine writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parsed {
    /// The [`TypeSpec::name`] of its family.
    pub family: &'static str,
    /// The type as the engine writes it; reading it again gives the same text.
    pub text: String,
}

/// Why a text is not a type a schema's version may use.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TypeError {
    /// Not a type of this engine at all, or written wrong, with why.
    NotAType(String),
    /// A type of this engine that the schema's version does not have.
    NotInVersion {
        /// The [`TypeSpec::name`] of its family.
        family: &'static str,
        /// The version it came in, when a later one has it; `None` when it was taken away.
        since: Option<&'static str>,
    },
}

impl fmt::Display for TypeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAType(why) => f.write_str(why),
            Self::NotInVersion { family, since: Some(v) } => write!(f, "`{family}` came in version {v}"),
            Self::NotInVersion { family, since: None } => write!(f, "`{family}` is not in this version"),
        }
    }
}

impl std::error::Error for TypeError {}

/// An engine's types.
pub trait Types: Send + Sync {
    /// Its groups, in palette order.
    fn groups(&self) -> &[TypeGroup];

    /// Every type, in palette order within each group.
    fn catalog(&self) -> &[TypeSpec];

    /// Reads a type written as text, as a column of a schema at `version` would have it.
    ///
    /// # Errors
    /// [`TypeError::NotAType`] when it is not a type of this engine; [`TypeError::NotInVersion`] when it is one that
    /// `version` does not have.
    fn parse(&self, text: &str, version: &str) -> Result<Parsed, TypeError>;
}
