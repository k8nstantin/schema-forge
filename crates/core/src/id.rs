//! Readable identities: made once from an object's kind and name, never changed (docs/model.md, Ids).

use std::fmt;

use serde::{Deserialize, Serialize};

/// What an id names; its letter starts the id (`t_orders`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    Namespace,
    Area,
    Table,
    View,
    Column,
    Key,
    Index,
    Check,
    Relationship,
    Sequence,
    Type,
    Kept,
}

impl Kind {
    /// The letter an id of this kind starts with.
    #[must_use]
    pub const fn prefix(self) -> &'static str {
        match self {
            Self::Namespace => "n",
            Self::Area => "a",
            Self::Table => "t",
            Self::View => "v",
            Self::Column => "c",
            Self::Key => "u",
            Self::Index => "i",
            Self::Check => "k",
            Self::Relationship => "r",
            Self::Sequence => "s",
            Self::Type => "y",
            Self::Kept => "x",
        }
    }
}

/// A readable id: a kind letter, an underscore, then lowercase words (`c_orders_total`).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Id(String);

/// An id that is not of the readable form.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
#[error("`{0}` is not an id: expected a kind letter, `_`, then lowercase letters, digits and `_`")]
pub struct BadId(pub String);

impl Id {
    /// The id for an object of `kind` named by `parts` (e.g. the table and the column), before checking it is
    /// free: names are lowercased and every run of other characters becomes one `_`.
    #[must_use]
    pub fn from_name(kind: Kind, parts: &[&str]) -> Self {
        let mut s = String::from(kind.prefix());
        for part in parts {
            let slug = slug(part);
            if !slug.is_empty() {
                s.push('_');
                s.push_str(&slug);
            }
        }
        if s.len() == 1 {
            s.push_str("_unnamed");
        }
        Self(s)
    }

    /// This id with `_2`, `_3`, … appended, for when it is taken.
    #[must_use]
    pub fn numbered(&self, n: u32) -> Self {
        Self(format!("{}_{n}", self.0))
    }

    /// The id as text.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn slug(name: &str) -> String {
    let mut out = String::new();
    let mut gap = false;
    for ch in name.chars() {
        if ch.is_ascii_alphanumeric() {
            if gap && !out.is_empty() {
                out.push('_');
            }
            gap = false;
            out.push(ch.to_ascii_lowercase());
        } else {
            gap = true;
        }
    }
    out
}

impl TryFrom<String> for Id {
    type Error = BadId;

    fn try_from(s: String) -> Result<Self, BadId> {
        let mut parts = s.splitn(2, '_');
        let kind = parts.next().unwrap_or_default();
        let rest = parts.next().unwrap_or_default();
        let ok = kind.len() == 1
            && kind.chars().all(|c| c.is_ascii_lowercase())
            && !rest.is_empty()
            && rest.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
        if ok { Ok(Self(s)) } else { Err(BadId(s)) }
    }
}

impl From<Id> for String {
    fn from(id: Id) -> Self {
        id.0
    }
}

impl fmt::Display for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_id_is_made_from_its_kind_and_names() {
        assert_eq!(Id::from_name(Kind::Table, &["orders"]).as_str(), "t_orders");
        assert_eq!(Id::from_name(Kind::Column, &["Orders", "orderTotal"]).as_str(), "c_orders_ordertotal");
        assert_eq!(Id::from_name(Kind::Relationship, &["fk orders→customers"]).as_str(), "r_fk_orders_customers");
        assert_eq!(Id::from_name(Kind::Table, &["—"]).as_str(), "t_unnamed");
        assert_eq!(Id::from_name(Kind::Table, &["orders"]).numbered(2).as_str(), "t_orders_2");
    }

    #[test]
    fn only_readable_ids_are_read() {
        assert!(Id::try_from("t_orders".to_string()).is_ok());
        for bad in ["orders", "T_orders", "tt_orders", "t_", "t_Orders", "t-orders"] {
            assert_eq!(Id::try_from(bad.to_string()), Err(BadId(bad.to_string())), "{bad}");
        }
    }
}
