//! Typed names: an object is named by where it is, its kind and its name, never by text joined with a separator; an
//! account by its user and host. Quoting helpers for the statements the engine writes and sends.

use std::fmt;

/// Where an object is: in a database, or in the server itself (its accounts, tablespaces, components).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Scope {
    /// A database of the server.
    Database(String),
    /// The server.
    Server,
}

/// The kinds of object engine_mysql declares (`engines/mysql/seeds/engine.sql`), in the seeds' order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Kind {
    /// A table.
    Table,
    /// A view.
    View,
    /// A stored procedure.
    Procedure,
    /// A stored function.
    Function,
    /// A trigger.
    Trigger,
    /// A scheduled event.
    Event,
    /// A JavaScript library (9.7).
    Library,
    /// A general tablespace.
    Tablespace,
    /// A spatial reference system made on the server.
    SpatialReferenceSystem,
    /// An account.
    Account,
    /// A role.
    Role,
    /// A server a FEDERATED table connects through.
    Server,
    /// A resource group.
    ResourceGroup,
    /// A component.
    Component,
    /// A loadable function.
    LoadableFunction,
    /// A Percona compression dictionary.
    CompressionDictionary,
}

impl Kind {
    /// The kind as `cortex.objects.kind` names it.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Table => "table",
            Kind::View => "view",
            Kind::Procedure => "procedure",
            Kind::Function => "function",
            Kind::Trigger => "trigger",
            Kind::Event => "event",
            Kind::Library => "library",
            Kind::Tablespace => "tablespace",
            Kind::SpatialReferenceSystem => "spatial_reference_system",
            Kind::Account => "account",
            Kind::Role => "role",
            Kind::Server => "server",
            Kind::ResourceGroup => "resource_group",
            Kind::Component => "component",
            Kind::LoadableFunction => "loadable_function",
            Kind::CompressionDictionary => "compression_dictionary",
        }
    }

    /// The kind of a name `cortex.objects.kind` holds.
    #[must_use]
    pub fn parse(name: &str) -> Option<Kind> {
        Some(match name {
            "table" => Kind::Table,
            "view" => Kind::View,
            "procedure" => Kind::Procedure,
            "function" => Kind::Function,
            "trigger" => Kind::Trigger,
            "event" => Kind::Event,
            "library" => Kind::Library,
            "tablespace" => Kind::Tablespace,
            "spatial_reference_system" => Kind::SpatialReferenceSystem,
            "account" => Kind::Account,
            "role" => Kind::Role,
            "server" => Kind::Server,
            "resource_group" => Kind::ResourceGroup,
            "component" => Kind::Component,
            "loadable_function" => Kind::LoadableFunction,
            "compression_dictionary" => Kind::CompressionDictionary,
            _ => return None,
        })
    }
}

/// An object: where it is, its kind and its name.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ObjectKey {
    /// Where it is.
    pub scope: Scope,
    /// What it is.
    pub kind: Kind,
    /// Its name as the server names it.
    pub name: String,
}

impl ObjectKey {
    /// An object of a database.
    #[must_use]
    pub fn in_database(database: &str, kind: Kind, name: &str) -> ObjectKey {
        ObjectKey {
            scope: Scope::Database(database.to_string()),
            kind,
            name: name.to_string(),
        }
    }

    /// An object of the server itself.
    #[must_use]
    pub fn of_server(kind: Kind, name: &str) -> ObjectKey {
        ObjectKey {
            scope: Scope::Server,
            kind,
            name: name.to_string(),
        }
    }

    /// The database, for an object of one.
    #[must_use]
    pub fn database(&self) -> Option<&str> {
        match &self.scope {
            Scope::Database(d) => Some(d),
            Scope::Server => None,
        }
    }
}

impl fmt::Display for ObjectKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.scope {
            Scope::Database(d) => write!(f, "{} {d}.{}", self.kind.as_str(), self.name),
            Scope::Server => write!(f, "{} {}", self.kind.as_str(), self.name),
        }
    }
}

/// An account or a role: its user and host.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct AccountName {
    /// The user part (empty for the anonymous account).
    pub user: String,
    /// The host part.
    pub host: String,
}

impl AccountName {
    /// An account of a user and a host.
    #[must_use]
    pub fn new(user: &str, host: &str) -> AccountName {
        AccountName {
            user: user.to_string(),
            host: host.to_string(),
        }
    }

    /// The name of the account's object: `user@host`.
    #[must_use]
    pub fn object_name(&self) -> String {
        format!("{}@{}", self.user, self.host)
    }

    /// The account of an object's name: the user is everything before the last `@`.
    #[must_use]
    pub fn from_object_name(name: &str) -> AccountName {
        let (user, host) = name.rsplit_once('@').unwrap_or(("", name));
        AccountName::new(user, host)
    }
}

/// A name quoted: `a``b`.
#[must_use]
pub fn q(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}

/// A string literal: 'it''s', its backslashes doubled.
#[must_use]
pub fn lit(value: &str) -> String {
    format!("'{}'", value.replace('\\', "\\\\").replace('\'', "''"))
}

/// An account as MySQL writes it: 'user'@'host'.
#[must_use]
pub fn account_literal(account: &AccountName) -> String {
    format!("{}@{}", lit(&account.user), lit(&account.host))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_account_name_splits_at_its_last_at_sign() {
        let name = AccountName::from_object_name("a@b@localhost");
        assert_eq!(name, AccountName::new("a@b", "localhost"));
        assert_eq!(name.object_name(), "a@b@localhost");
        assert_eq!(account_literal(&name), "'a@b'@'localhost'");
    }

    #[test]
    fn names_and_strings_are_quoted_as_mysql_reads_them() {
        assert_eq!(q("a`b"), "`a``b`");
        assert_eq!(lit(r"it's a\b"), r"'it''s a\\b'");
    }

    #[test]
    fn every_kind_names_itself_and_is_found_by_its_name() {
        let kinds = [
            Kind::Table,
            Kind::View,
            Kind::Procedure,
            Kind::Function,
            Kind::Trigger,
            Kind::Event,
            Kind::Library,
            Kind::Tablespace,
            Kind::SpatialReferenceSystem,
            Kind::Account,
            Kind::Role,
            Kind::Server,
            Kind::ResourceGroup,
            Kind::Component,
            Kind::LoadableFunction,
            Kind::CompressionDictionary,
        ];
        for kind in kinds {
            assert_eq!(Kind::parse(kind.as_str()), Some(kind));
        }
        assert_eq!(Kind::parse("index"), None);
    }
}
