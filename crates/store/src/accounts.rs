//! The service accounts the app signs in as, and their passwords, read from the accounts file the installer writes
//! (`<ROLE>_PASSWORD=...`, one per line, mode 600). A password is never printed: its `Debug` is redacted.

use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

use crate::StoreError;

/// An account of `schema_forge` (decision database-roles).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Account {
    /// `cortex_service`: the app. Writes designs, branches and the shared model; opens and ends turns; undoes.
    Service,
    /// `cortex_agent`: the coding agent. As the app, but reads designs, branches and locked versions only.
    Agent,
    /// `cortex_reader`: reads everything, writes nothing.
    Reader,
    /// `<namespace>_service`: a plugin's service account, the only writer of its namespace, fenced to its engine's
    /// designs. Holds the namespace (`engine_mysql`).
    Plugin(String),
}

impl Account {
    /// The database role this account signs in as.
    #[must_use]
    pub fn role(&self) -> String {
        match self {
            Account::Service => "cortex_service".into(),
            Account::Agent => "cortex_agent".into(),
            Account::Reader => "cortex_reader".into(),
            Account::Plugin(namespace) => format!("{namespace}_service"),
        }
    }

    /// The account of a role name, when it is one of `schema_forge`'s service accounts.
    #[must_use]
    pub fn from_role(role: &str) -> Option<Account> {
        match role {
            "cortex_service" => Some(Account::Service),
            "cortex_agent" => Some(Account::Agent),
            "cortex_reader" => Some(Account::Reader),
            _ => {
                let namespace = role.strip_suffix("_service")?;
                let valid = namespace.starts_with(|c: char| c.is_ascii_lowercase())
                    && namespace
                        .chars()
                        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
                    && !namespace.starts_with("cortex");
                valid.then(|| Account::Plugin(namespace.to_string()))
            }
        }
    }
}

impl fmt::Display for Account {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.role())
    }
}

/// A password, never printed.
#[derive(Clone)]
struct Secret(String);

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("***")
    }
}

/// The accounts this process may sign in as, each with its password.
#[derive(Clone, Debug, Default)]
pub struct Accounts {
    passwords: BTreeMap<Account, Secret>,
}

impl Accounts {
    /// Reads the accounts file. It must be readable by its owner alone (on Unix), and every line `<ROLE>_PASSWORD=...`
    /// of a known account; anything else is refused, naming the line, never the password.
    pub fn read(path: &Path) -> Result<Accounts, StoreError> {
        let fail = |reason: String| StoreError::Accounts {
            path: path.display().to_string(),
            reason,
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(path)
                .map_err(|e| fail(e.to_string()))?
                .permissions()
                .mode();
            if mode & 0o077 != 0 {
                return Err(fail(format!(
                    "readable by others (mode {:o}): it must be 600",
                    mode & 0o777
                )));
            }
        }
        let text = std::fs::read_to_string(path).map_err(|e| fail(e.to_string()))?;
        let mut accounts = Accounts::default();
        for (n, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (key, password) = line
                .split_once('=')
                .ok_or_else(|| fail(format!("line {} is not KEY=VALUE", n + 1)))?;
            let role = key
                .strip_suffix("_PASSWORD")
                .ok_or_else(|| fail(format!("line {}: {key} is not <ROLE>_PASSWORD", n + 1)))?
                .to_ascii_lowercase();
            let account = Account::from_role(&role)
                .ok_or_else(|| fail(format!("line {}: {role} is not an account of schema_forge", n + 1)))?;
            accounts.passwords.insert(account, Secret(password.to_string()));
        }
        Ok(accounts)
    }

    /// Accounts from (account, password) pairs, for a caller that holds them already.
    #[must_use]
    pub fn from_pairs(pairs: impl IntoIterator<Item = (Account, String)>) -> Accounts {
        Accounts {
            passwords: pairs.into_iter().map(|(a, p)| (a, Secret(p))).collect(),
        }
    }

    /// The same file narrowed to one account: what a process that needs only that account keeps (the MCP keeps
    /// `cortex_agent`'s alone, decision mcp-stdio).
    #[must_use]
    pub fn only(&self, account: &Account) -> Accounts {
        Accounts {
            passwords: self
                .passwords
                .iter()
                .filter(|(a, _)| *a == account)
                .map(|(a, s)| (a.clone(), s.clone()))
                .collect(),
        }
    }

    /// Every account held, in order.
    pub fn accounts(&self) -> impl Iterator<Item = &Account> {
        self.passwords.keys()
    }

    pub(crate) fn password(&self, account: &Account) -> Result<&str, StoreError> {
        self.passwords
            .get(account)
            .map(|s| s.0.as_str())
            .ok_or_else(|| StoreError::NoPassword(account.role()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roles_round_trip() {
        for a in [
            Account::Service,
            Account::Agent,
            Account::Reader,
            Account::Plugin("engine_mysql".into()),
        ] {
            assert_eq!(Account::from_role(&a.role()), Some(a));
        }
        assert_eq!(Account::from_role("postgres"), None);
        assert_eq!(Account::from_role("Engine_service"), None);
        assert_eq!(Account::from_role("cortex_owner"), None);
    }

    #[test]
    fn a_password_is_never_printed() {
        let accounts = Accounts::from_pairs([(Account::Service, "hunter2".to_string())]);
        assert!(!format!("{accounts:?}").contains("hunter2"));
    }

    #[test]
    fn only_keeps_one_account() {
        let accounts = Accounts::from_pairs([(Account::Service, "a".into()), (Account::Agent, "b".into())]);
        let agent = accounts.only(&Account::Agent);
        assert_eq!(agent.accounts().collect::<Vec<_>>(), vec![&Account::Agent]);
        assert!(agent.password(&Account::Service).is_err());
    }
}
