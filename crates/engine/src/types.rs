//! An engine's types: what the palette shows, what a column may be, and how a type is written.

use crate::{Availability, Version};

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
    /// A real type of this family as a column would have it, ready to use (`decimal(18,2)`); it reads back as itself.
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

/// An engine's types.
pub trait Types: Send + Sync {
    /// Its groups, in palette order.
    fn groups(&self) -> &[TypeGroup];

    /// Every type, in palette order within each group.
    fn catalog(&self) -> &[TypeSpec];

    /// Reads a type written as text, as a column of a schema at `version` would have it.
    ///
    /// # Errors
    /// When it is not a type of this engine, or not one `version` has, saying why.
    fn parse(&self, text: &str, version: &str) -> Result<Parsed, String>;

    /// The types a schema at `version` may use.
    fn in_version<'a>(&'a self, version: &str, versions: &[Version]) -> Vec<&'a TypeSpec> {
        self.catalog().iter().filter(|t| t.available.in_version(version, versions)).collect()
    }
}
