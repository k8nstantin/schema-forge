//! Reading a schema from the live database (docs/connections.xml). An engine declares the fields a connection needs as
//! data, tests a connection step by step, and reads the schema read-only. The app keeps the profiles and their secrets
//! and builds the Connections page from the declared fields; the engine never stores a secret, and the agent never
//! sees one.

use std::collections::BTreeMap;
use std::fmt;

use crate::Imported;

/// A field of a connection, declared by its engine: what the Connections page shows and asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub struct Field {
    /// As a profile names it (`host`, `port`, `tls`).
    pub key: &'static str,
    /// As people read it (`"Host"`).
    pub label: &'static str,
    pub kind: FieldKind,
    /// What it is when the person gives none; `None` when it has none.
    pub default: Option<&'static str>,
    /// A plain sentence shown beside it.
    pub help: &'static str,
    pub required: bool,
}

impl Field {
    /// A field that may be left empty, with no default.
    #[must_use]
    pub const fn new(key: &'static str, label: &'static str, kind: FieldKind, help: &'static str) -> Self {
        Self { key, label, kind, default: None, help, required: false }
    }

    /// The same field, which must be given.
    #[must_use]
    pub const fn required(self) -> Self {
        Self { required: true, ..self }
    }

    /// The same field, with what it is when none is given.
    #[must_use]
    pub const fn default(self, value: &'static str) -> Self {
        Self { default: Some(value), ..self }
    }
}

/// The kind of value a connection field holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum FieldKind {
    Text,
    /// A whole number (a port, a timeout in seconds).
    Number,
    /// One of these words (a TLS mode).
    OneOf(&'static [&'static str]),
    /// A path on this machine (a certificate).
    Path,
    /// The secret (a password, a token): never stored in a profile, kept where the person chooses.
    Secret,
}

/// A connection's values, by field key: never its secret.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
#[non_exhaustive]
pub struct Profile {
    pub values: BTreeMap<String, String>,
}

impl Profile {
    #[must_use]
    pub fn new(values: BTreeMap<String, String>) -> Self {
        Self { values }
    }

    /// The value of `key`, or the field's default.
    #[must_use]
    pub fn get<'a>(&'a self, key: &str, fields: &'a [Field]) -> Option<&'a str> {
        self.values
            .get(key)
            .map(String::as_str)
            .filter(|v| !v.is_empty())
            .or_else(|| fields.iter().find(|f| f.key == key).and_then(|f| f.default))
    }
}

/// A secret, handed to the engine for one test or read: it never prints, and is never stored by the engine.
#[derive(Clone, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    #[must_use]
    pub fn new(secret: impl Into<String>) -> Self {
        Self(secret.into())
    }

    /// The secret itself, for the engine's driver only.
    #[must_use]
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(…)")
    }
}

/// One step of testing a connection, and how it went.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct Step {
    pub step: StepKind,
    pub outcome: Outcome,
    /// What happened, in a sentence: what was reached, which version, what is missing.
    pub said: String,
}

impl Step {
    #[must_use]
    pub fn new(step: StepKind, outcome: Outcome, said: impl Into<String>) -> Self {
        Self { step, outcome, said: said.into() }
    }
}

/// The steps a connection test takes, in order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum StepKind {
    /// The host answers on the port.
    Reach,
    /// TLS as the profile asks.
    Secure,
    /// The user and the secret are accepted.
    SignIn,
    /// The server's version, and so the engine version a schema read from it is designed for.
    Version,
    /// The rights to read the definitions, and whether the user can also change anything.
    Rights,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum Outcome {
    Passed,
    /// It works, with something the person should know (a user that can change the schema, TLS turned off).
    Warning,
    Failed,
    /// Not tried, because a step before it failed.
    Skipped,
}

/// Reading a schema from the live database, read-only.
pub trait Live: Send + Sync {
    /// The fields a connection needs, in the order the Connections page shows them.
    fn fields(&self) -> &[Field];

    /// Tests a connection, every step in order, and stops at the first that fails (the rest skipped).
    fn test(&self, profile: &Profile, secret: Option<&Secret>) -> Vec<Step>;

    /// Reads the schema from the namespaces named in `which` (all the connection reaches when empty), sending only
    /// statements that read, with a report that adds up as a file read's does.
    ///
    /// # Errors
    /// When the connection cannot be made, or what it reads cannot be read at all.
    fn read(&self, profile: &Profile, secret: Option<&Secret>, which: &[String]) -> Result<Imported, String>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_secret_never_prints() {
        let s = Secret::new("hunter2");
        assert_eq!(format!("{s:?}"), "Secret(…)");
        assert_eq!(s.expose(), "hunter2");
    }

    #[test]
    fn a_profile_falls_back_to_the_fields_default() {
        const FIELDS: &[Field] = &[Field::new("port", "Port", FieldKind::Number, "Where it listens").default("3306")];
        let p = Profile::new(BTreeMap::from([("host".to_string(), "db".to_string())]));
        assert_eq!(p.get("port", FIELDS), Some("3306"));
        assert_eq!(p.get("host", FIELDS), Some("db"));
        assert_eq!(p.get("user", FIELDS), None);
    }
}
