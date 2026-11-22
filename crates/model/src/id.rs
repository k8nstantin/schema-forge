//! Ids: the stable identity of everything in a schema. A rename changes a name, never an id, so a migration renames
//! instead of dropping and making again.

use std::collections::HashSet;
use std::fmt;

use serde::{Deserialize, Serialize};

/// The longest id.
const MAX: usize = 128;

/// An id: lowercase ASCII letters, digits and `_`, starting with a letter, at most 128 long. Readable, made from the
/// thing's kind and name (`o_orders`, `c_orders_total`), and kept when the name changes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Id(String);

/// Why a text is not an id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdError(pub String);

impl fmt::Display for IdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for IdError {}

impl TryFrom<String> for Id {
    type Error = IdError;

    fn try_from(s: String) -> Result<Self, IdError> {
        let ok = !s.is_empty()
            && s.len() <= MAX
            && s.starts_with(|c: char| c.is_ascii_lowercase())
            && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
        if ok {
            Ok(Self(s))
        } else {
            Err(IdError(format!(
                "`{s}` is not an id: lowercase letters, digits and `_`, starting with a letter, at most {MAX} long"
            )))
        }
    }
}

impl TryFrom<&str> for Id {
    type Error = IdError;

    fn try_from(s: &str) -> Result<Self, IdError> {
        Self::try_from(s.to_string())
    }
}

impl From<Id> for String {
    fn from(id: Id) -> Self {
        id.0
    }
}

impl Id {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// What an id is for: its prefix.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Namespace,
    Object,
    Column,
    Link,
    Area,
}

impl Kind {
    const fn prefix(self) -> &'static str {
        match self {
            Self::Namespace => "n",
            Self::Object => "o",
            Self::Column => "c",
            Self::Link => "l",
            Self::Area => "a",
        }
    }
}

/// Gives out ids, each one once: an id made from a name, numbered when it is taken (`o_orders`, `o_orders_2`).
#[derive(Debug, Default, Clone)]
pub struct Ids {
    taken: HashSet<Id>,
}

impl Ids {
    /// Every id the schema already holds is taken.
    #[must_use]
    pub fn of(schema: &crate::Schema) -> Self {
        let mut ids = Self::default();
        for id in schema.ids() {
            ids.taken.insert(id.clone());
        }
        ids
    }

    /// A new id for `kind`, from the names in `parts` (`["orders", "total"]` for a column gives `c_orders_total`):
    /// each part lowercased, every other character `_`, numbered when taken.
    pub fn next(&mut self, kind: Kind, parts: &[&str]) -> Id {
        let mut base = kind.prefix().to_string();
        for part in parts {
            base.push('_');
            base.extend(part.chars().map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '_' }));
        }
        // Room for the number at the end.
        base.truncate(MAX - 8);
        let mut candidate = base.clone();
        let mut n = 2;
        loop {
            let id = Id(candidate.clone());
            if !self.taken.contains(&id) {
                self.taken.insert(id.clone());
                return id;
            }
            candidate = format!("{base}_{n}");
            n += 1;
        }
    }

    /// Marks `id` taken; false when it already was.
    pub fn take(&mut self, id: &Id) -> bool {
        self.taken.insert(id.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_readable_and_strict() {
        assert!(Id::try_from("o_orders").is_ok());
        assert!(Id::try_from("c_orders_total_2").is_ok());
        for bad in ["", "Orders", "1st", "_x", "o-orders", "o orders", "o_ö"] {
            assert!(Id::try_from(bad).is_err(), "{bad}");
        }
        assert!(Id::try_from("a".repeat(MAX)).is_ok());
        assert!(Id::try_from("a".repeat(MAX + 1)).is_err());
    }

    #[test]
    fn each_id_is_given_once() {
        let mut ids = Ids::default();
        assert_eq!(ids.next(Kind::Object, &["Orders"]).as_str(), "o_orders");
        assert_eq!(ids.next(Kind::Object, &["orders"]).as_str(), "o_orders_2");
        assert_eq!(ids.next(Kind::Object, &["orders"]).as_str(), "o_orders_3");
        assert_eq!(ids.next(Kind::Column, &["orders", "Total Due"]).as_str(), "c_orders_total_due");
        assert_eq!(ids.next(Kind::Namespace, &["sales", "2024"]).as_str(), "n_sales_2024");
        assert!(!ids.take(&Id::try_from("o_orders").expect("an id")));
        assert!(ids.take(&Id::try_from("o_refunds").expect("an id")));
    }

    #[test]
    fn a_long_name_still_gives_a_valid_id() {
        let mut ids = Ids::default();
        let long = "x".repeat(400);
        let a = ids.next(Kind::Object, &[&long]);
        let b = ids.next(Kind::Object, &[&long]);
        assert!(Id::try_from(a.as_str()).is_ok() && Id::try_from(b.as_str()).is_ok());
        assert_ne!(a, b);
    }
}
