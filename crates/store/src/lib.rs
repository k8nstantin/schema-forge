//! The store: `schema_forge` signed in to as its service accounts, one connection pool per account.
//!
//! Every write is one SERIALIZABLE transaction (decision many-writers) and is given as a function the store can run
//! again: on a serialization failure or a deadlock the whole transaction, the logic that chose what to write included,
//! runs again after a bounded, jittered pause (the guidance of `PostgreSQL`'s manual; decision operation-transaction). An operation
//! names itself to the history trigger with `set_config(..., true)`, for its transaction alone, so a pooled connection
//! never carries it into another caller's work. The bell ([`Bell`]) hears every committed turn.

mod accounts;
mod bell;
mod endpoint;
mod error;

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use tokio_postgres::IsolationLevel;
use uuid::Uuid;

pub use accounts::{Account, Accounts};
pub use bell::{Bell, BellOptions, Ring};
pub use endpoint::{Endpoint, Tls};
pub use error::{DEADLOCK, INSUFFICIENT_PRIVILEGE, SERIALIZATION_FAILURE, StoreError};
pub use tokio_postgres::types::ToSql;
pub use tokio_postgres::{Row, Transaction};

/// How a write that collided with other writers is tried again.
#[derive(Clone, Copy, Debug)]
pub struct RetryPolicy {
    /// How many times in all, the first included.
    pub attempts: u32,
    /// The longest first pause.
    pub first: Duration,
    /// The longest pause.
    pub max: Duration,
}

impl Default for RetryPolicy {
    fn default() -> RetryPolicy {
        RetryPolicy {
            attempts: 10,
            first: Duration::from_millis(10),
            max: Duration::from_secs(1),
        }
    }
}

impl RetryPolicy {
    /// Full jitter: a pause anywhere from nothing to the attempt's ceiling, which doubles each time up to `max`.
    fn pause(&self, attempt: u32) -> Duration {
        let ceiling = self.first.saturating_mul(1 << attempt.min(16)).min(self.max);
        let ceiling_ms = u64::try_from(ceiling.as_millis()).unwrap_or(u64::MAX);
        Duration::from_millis(fastrand::u64(0..=ceiling_ms))
    }
}

/// The store, as the accounts this process holds.
pub struct Store {
    endpoint: Endpoint,
    accounts: Accounts,
    pools: Mutex<HashMap<Account, Pool>>,
    pool_size: usize,
    policy: RetryPolicy,
    retries: AtomicU64,
}

impl Store {
    /// A store at an endpoint, signed in to as the accounts given. No connection is made until one is needed.
    #[must_use]
    pub fn new(endpoint: Endpoint, accounts: Accounts) -> Store {
        Store {
            endpoint,
            accounts,
            pools: Mutex::new(HashMap::new()),
            pool_size: 8,
            policy: RetryPolicy::default(),
            retries: AtomicU64::new(0),
        }
    }

    /// The most connections each account's pool keeps.
    #[must_use]
    pub fn with_pool_size(mut self, size: usize) -> Store {
        self.pool_size = size.max(1);
        self
    }

    /// How a write that collided is tried again.
    #[must_use]
    pub fn with_retry_policy(mut self, policy: RetryPolicy) -> Store {
        self.policy = policy;
        self
    }

    /// Where the store is.
    #[must_use]
    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }

    /// The accounts held.
    #[must_use]
    pub fn accounts(&self) -> &Accounts {
        &self.accounts
    }

    /// How many times, in all, a write was run again after colliding with another writer.
    #[must_use]
    pub fn retries(&self) -> u64 {
        self.retries.load(Ordering::Relaxed)
    }

    fn pool(&self, account: &Account) -> Result<Pool, StoreError> {
        let mut pools = self
            .pools
            .lock()
            .map_err(|_| StoreError::Lost("the pool table was poisoned".into()))?;
        if let Some(pool) = pools.get(account) {
            return Ok(pool.clone());
        }
        let config = self.endpoint.config(&account.role(), self.accounts.password(account)?);
        let manager_config = ManagerConfig {
            recycling_method: RecyclingMethod::Fast,
        };
        let manager = match self.endpoint.tls {
            Tls::Disable => Manager::from_config(config, tokio_postgres::NoTls, manager_config),
            Tls::Require => Manager::from_config(config, Endpoint::connector()?, manager_config),
        };
        let pool = Pool::builder(manager)
            .max_size(self.pool_size)
            .build()
            .map_err(|e| StoreError::Connect {
                role: account.role(),
                reason: e.to_string(),
            })?;
        pools.insert(account.clone(), pool.clone());
        Ok(pool)
    }

    async fn client(&self, account: &Account) -> Result<deadpool_postgres::Object, StoreError> {
        self.pool(account)?.get().await.map_err(|e| StoreError::Connect {
            role: account.role(),
            reason: e.to_string(),
        })
    }

    /// Runs `work` in one SERIALIZABLE transaction as `account`, and commits it. On a serialization failure or a
    /// deadlock the whole transaction is rolled back and `work` runs again, after a jittered pause, up to the retry
    /// policy's attempts. Any other refusal comes back as it is.
    pub async fn write<T>(
        &self,
        account: &Account,
        mut work: impl AsyncFnMut(&Transaction<'_>) -> Result<T, StoreError>,
    ) -> Result<T, StoreError> {
        let mut attempt = 0;
        loop {
            attempt += 1;
            let mut client = self.client(account).await?;
            let tx = client
                .build_transaction()
                .isolation_level(IsolationLevel::Serializable)
                .start()
                .await?;
            let result = match work(&tx).await {
                Ok(value) => tx.commit().await.map(|()| value).map_err(StoreError::from),
                Err(e) => {
                    let _ = tx.rollback().await;
                    Err(e)
                }
            };
            match result {
                Ok(value) => return Ok(value),
                Err(e) if e.is_retryable() && attempt < self.policy.attempts => {
                    self.retries.fetch_add(1, Ordering::Relaxed);
                    tracing::debug!(%account, attempt, error = %e, "a write collided; running it again");
                    drop(client);
                    tokio::time::sleep(self.policy.pause(attempt)).await;
                }
                Err(e) if e.is_retryable() => {
                    return Err(StoreError::Exhausted {
                        attempts: attempt,
                        last: Box::new(e),
                    });
                }
                Err(e) => return Err(e),
            }
        }
    }

    /// Runs `work` in one REPEATABLE READ, READ ONLY transaction as `account`: one consistent snapshot, never a
    /// serialization failure.
    pub async fn read<T>(
        &self,
        account: &Account,
        work: impl AsyncFnOnce(&Transaction<'_>) -> Result<T, StoreError>,
    ) -> Result<T, StoreError> {
        let mut client = self.client(account).await?;
        let tx = client
            .build_transaction()
            .isolation_level(IsolationLevel::RepeatableRead)
            .read_only(true)
            .start()
            .await?;
        let value = work(&tx).await?;
        tx.commit().await?;
        Ok(value)
    }
}

/// Inside a write: adds an operation to an open turn, in the next place, and names it to the history trigger for this
/// transaction alone. Every row the transaction changes afterwards is logged under it.
pub async fn begin_operation(
    tx: &Transaction<'_>,
    design: Uuid,
    turn: Uuid,
    kind: &str,
    summary: &str,
) -> Result<Uuid, StoreError> {
    let row = tx
        .query_one(
            "INSERT INTO cortex.operations (design, turn, position, kind, summary) \
             VALUES ($1, $2, (SELECT coalesce(max(position), 0) + 1 FROM cortex.operations WHERE turn = $2), $3, $4) RETURNING id",
            &[&design, &turn, &kind, &summary],
        )
        .await?;
    let operation: Uuid = row.get(0);
    tx.execute(
        "SELECT set_config('schema_forge.operation', $1, true)",
        &[&operation.to_string()],
    )
    .await?;
    Ok(operation)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pauses_stay_under_their_ceiling() {
        let policy = RetryPolicy::default();
        for attempt in 1..40 {
            assert!(policy.pause(attempt) <= policy.max);
        }
    }

    #[test]
    fn only_collisions_are_retried() {
        let refused = |code: &str, constraint: Option<&str>| StoreError::Refused {
            code: code.into(),
            message: String::new(),
            constraint: constraint.map(str::to_string),
            detail: None,
        };
        assert!(refused(SERIALIZATION_FAILURE, None).is_retryable());
        assert!(refused(DEADLOCK, None).is_retryable());
        assert!(refused("23505", Some("operations_turn_position_key")).is_retryable());
        assert!(!refused("23505", Some("designs_name_key")).is_retryable());
        assert!(!refused(INSUFFICIENT_PRIVILEGE, None).is_retryable());
        assert!(!StoreError::TurnHeld { design: String::new() }.is_retryable());
    }
}
