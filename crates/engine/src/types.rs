//! An engine's types: what the palette shows, what a column may be, and how a type is written.
//!
//! The types here are made with their constructors (`TypeSpec::new(…).since("3")`), never by naming every field, so a
//! field added to the interface later breaks no engine.

use std::fmt;

use crate::Availability;

/// A group of types in the palette, in the order the engine lists them (whole numbers, exact decimals, text…).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub struct TypeGroup {
    pub id: &'static str,
    pub title: &'static str,
}

impl TypeGroup {
    #[must_use]
    pub const fn new(id: &'static str, title: &'static str) -> Self {
        Self { id, title }
    }
}

/// One type, or one family of types that take parameters (`decimal(P,S)`).
///
/// An engine makes it with [`TypeSpec::new`], never field by field, so a field added later breaks no engine:
///
/// ```compile_fail
/// use schema_forge_engine::{Availability, TypeSpec};
/// let t = TypeSpec { name: "int", group: "whole", meaning: "A whole number", example: "int", available: Availability::ALWAYS };
/// ```
///
/// ```
/// use schema_forge_engine::TypeSpec;
/// const WIDE: TypeSpec = TypeSpec::new("wide", "text", "Wide text", "wide").since("2");
/// assert_eq!(WIDE.available.since, Some("2"));
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
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

impl TypeSpec {
    /// A type in every version.
    #[must_use]
    pub const fn new(name: &'static str, group: &'static str, meaning: &'static str, example: &'static str) -> Self {
        Self { name, group, meaning, example, available: Availability::ALWAYS }
    }

    /// The same type, only in the versions `available` says.
    #[must_use]
    pub const fn available(self, available: Availability) -> Self {
        Self { available, ..self }
    }

    /// The same type, from `version` on.
    #[must_use]
    pub const fn since(self, version: &'static str) -> Self {
        self.available(Availability::since(version))
    }
}

/// A type read from text: which family it is, and how the engine writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct Parsed {
    /// The [`TypeSpec::name`] of its family.
    pub family: &'static str,
    /// The type as the engine writes it; reading it again gives the same text.
    pub text: String,
}

impl Parsed {
    #[must_use]
    pub fn new(family: &'static str, text: impl Into<String>) -> Self {
        Self { family, text: text.into() }
    }
}

/// Why a text is not a type a schema's version may use. More reasons may come: match it with a wildcard.
///
/// ```compile_fail
/// use schema_forge_engine::TypeError;
/// fn why(e: TypeError) -> u8 { match e { TypeError::NotAType(_) => 1, TypeError::NotInVersion { .. } => 2 } }
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum TypeError {
    /// Not a type of this engine at all, or written wrong, with why.
    NotAType(String),
    /// A type of this engine that the schema's version does not have.
    NotInVersion {
        /// The [`TypeSpec::name`] of its family.
        family: &'static str,
        /// The version it came in, when the schema's version is before it ([`Availability::since`]); `None` when a
        /// version at or before the schema's took it away.
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
    /// `version` does not have, with the version it came in exactly as its [`TypeSpec::available`] says.
    fn parse(&self, text: &str, version: &str) -> Result<Parsed, TypeError>;
}
