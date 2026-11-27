//! What can go wrong talking to the store. A refusal by the database keeps its SQLSTATE, so a caller can tell a rule
//! (23514, a check), a missing privilege (42501) and a conflict apart; a serialization failure is retried by the store
//! itself and reaches a caller only when the retries ran out.

/// An error of the store.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    /// The accounts file is missing, readable by others, or not of the expected form.
    #[error("the accounts file {path}: {reason}")]
    Accounts {
        /// The file.
        path: String,
        /// What is wrong with it (never a password).
        reason: String,
    },
    /// The accounts file holds no password for the account.
    #[error("no password for {0} in the accounts file")]
    NoPassword(String),
    /// The account could not reach the store.
    #[error("{role} cannot reach the store: {reason}")]
    Connect {
        /// The role that tried.
        role: String,
        /// Why.
        reason: String,
    },
    /// The connection broke during the work.
    #[error("the connection to the store broke: {0}")]
    Lost(String),
    /// The database refused the work: a rule, a privilege, a conflict.
    #[error("refused ({code}): {message}")]
    Refused {
        /// The SQLSTATE (`42501`, `23514`).
        code: String,
        /// The database's message.
        message: String,
        /// The constraint that refused it, when one did.
        constraint: Option<String>,
        /// The database's detail, when it gave one.
        detail: Option<String>,
    },
    /// The design already has an open turn (decision one-open-turn).
    #[error("the design {design} already has an open turn")]
    TurnHeld {
        /// The design, as the database named it.
        design: String,
    },
    /// Work the caller asked for that the rules do not allow, refused before it reached the database.
    #[error("{0}")]
    Invalid(String),
    /// The work collided with other writers every time it was tried.
    #[error("gave up after {attempts} attempts: {last}")]
    Exhausted {
        /// How many times it was tried.
        attempts: u32,
        /// The last failure.
        last: Box<StoreError>,
    },
    /// TLS could not be set up.
    #[error("TLS: {0}")]
    Tls(String),
}

/// A serialization failure: the transaction is run again, whole (the guidance of `PostgreSQL`'s manual).
pub const SERIALIZATION_FAILURE: &str = "40001";
/// A deadlock: the transaction is run again, whole.
pub const DEADLOCK: &str = "40P01";
/// A missing privilege, or a change outside an operation.
pub const INSUFFICIENT_PRIVILEGE: &str = "42501";

impl StoreError {
    /// The SQLSTATE of a refusal.
    #[must_use]
    pub fn code(&self) -> Option<&str> {
        match self {
            StoreError::Refused { code, .. } => Some(code),
            StoreError::Exhausted { last, .. } => last.code(),
            _ => None,
        }
    }

    /// Whether running the whole transaction again may succeed: a serialization failure, a deadlock, or two
    /// operations of one turn that took the same place at once.
    #[must_use]
    pub fn is_retryable(&self) -> bool {
        match self {
            StoreError::Refused { code, constraint, .. } => {
                code == SERIALIZATION_FAILURE
                    || code == DEADLOCK
                    || (code == "23505" && constraint.as_deref() == Some("operations_turn_position_key"))
            }
            _ => false,
        }
    }
}

impl From<tokio_postgres::Error> for StoreError {
    fn from(e: tokio_postgres::Error) -> StoreError {
        let Some(db) = e.as_db_error() else {
            return StoreError::Lost(e.to_string());
        };
        if db.code().code() == "23505" && db.constraint() == Some("turns_one_open") {
            // Key (design)=(0193...) already exists.
            let design = db
                .detail()
                .and_then(|d| {
                    d.split_once(")=(")
                        .map(|(_, rest)| rest.split(')').next().unwrap_or_default().to_string())
                })
                .unwrap_or_default();
            return StoreError::TurnHeld { design };
        }
        StoreError::Refused {
            code: db.code().code().to_string(),
            message: db.message().to_string(),
            constraint: db.constraint().map(str::to_string),
            detail: db.detail().map(str::to_string),
        }
    }
}
