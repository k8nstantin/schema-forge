//! The core: designs, branches, turns, operations, undo, restore and locked versions, on the cortex's own functions.
//! It never names an engine: what only an engine knows, its plugin writes, as its own account, in a turn the app or the
//! agent opened (decision plugin-operations).
//!
//! A turn is one round of work on a design; a design has at most one open turn, held by the database (decision
//! one-open-turn). An operation is one step of a turn and one transaction on one account: it lands whole or not at
//! all, and every row it changes is logged by the cortex, so any committed turn can be undone exactly. Undo, restore
//! and branch switch are turns too, each a single transaction.

mod ids;
mod model;

use schema_forge_store::{Account, Row, Store, StoreError, Transaction, begin_operation};

pub use ids::{BranchId, DesignId, LockedVersionId, OperationId, TurnId};
pub use model::{MODEL_TABLES, Model};

/// What can go wrong in the core.
#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    /// The store refused or failed.
    #[error(transparent)]
    Store(#[from] StoreError),
    /// The design already has an open turn: who holds it, and since when.
    #[error("the design {design} is held by turn {turn}, a {kind} turn of {author} open since {since}")]
    TurnHeld {
        /// The design.
        design: DesignId,
        /// The open turn.
        turn: TurnId,
        /// Who opened it.
        author: String,
        /// What kind of turn it is.
        kind: String,
        /// When it was opened.
        since: String,
    },
    /// A turn with operations cannot be rejected: its rows are in the model. Commit it, then undo it.
    #[error("turn {0} has operations: commit it, then undo it")]
    NotEmpty(TurnId),
    /// Nothing of that id.
    #[error("not found: {0}")]
    NotFound(String),
    /// The account may not do this.
    #[error("{account} may not {what}")]
    NotAllowed {
        /// The account.
        account: String,
        /// What it tried.
        what: &'static str,
    },
}

/// What made a turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TurnKind {
    /// A live server or a dump read in.
    Import,
    /// A person's edit.
    Edit,
    /// The agent's answer to a prompt.
    Agent,
    /// An undo of one turn.
    Undo,
    /// A restore to an earlier turn.
    Restore,
    /// A switch of branch.
    Switch,
}

impl TurnKind {
    /// As the cortex names it.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            TurnKind::Import => "import",
            TurnKind::Edit => "edit",
            TurnKind::Agent => "agent",
            TurnKind::Undo => "undo",
            TurnKind::Restore => "restore",
            TurnKind::Switch => "switch",
        }
    }
}

/// A design to make.
#[derive(Clone, Debug)]
pub struct NewDesign {
    /// As people call it.
    pub name: String,
    /// The engine (`mysql`).
    pub engine: String,
    /// The engine's version (`8.4`).
    pub version: String,
    /// The engine's flavor (`mysql`, `percona`, `aurora`).
    pub flavor: String,
    /// What it is for.
    pub comment: Option<String>,
}

/// A design and its main branch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Design {
    /// Its id.
    pub id: DesignId,
    /// Its name.
    pub name: String,
    /// Its engine.
    pub engine: String,
    /// Its engine's version.
    pub version: String,
    /// Its engine's flavor.
    pub flavor: String,
    /// Its main branch.
    pub main: BranchId,
}

/// A turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Turn {
    /// Its id.
    pub id: TurnId,
    /// Its design.
    pub design: DesignId,
    /// Its branch.
    pub branch: BranchId,
    /// What made it.
    pub kind: String,
    /// open, committed, rejected or undone.
    pub state: String,
    /// Its number in the design's commit order, once committed.
    pub seq: Option<i32>,
    /// Who made it.
    pub author: String,
}

impl Turn {
    fn from_row(row: &Row) -> Turn {
        Turn {
            id: row.get("id"),
            design: row.get("design"),
            branch: row.get("branch"),
            kind: row.get("kind"),
            state: row.get("state"),
            seq: row.get("seq"),
            author: row.get("author"),
        }
    }
}

const TURN: &str = "id, design, branch, kind, state, seq, author";

/// A locked version of a design.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LockedVersion {
    /// Its id.
    pub id: LockedVersionId,
    /// Its number in the design: 1, 2, 3.
    pub number: i32,
    /// The last turn it holds.
    pub turn: TurnId,
    /// The SHA-256 of the model at that turn.
    pub hash: String,
}

/// The cortex, as the app and the agent use it.
pub struct Cortex {
    store: Store,
}

impl Cortex {
    /// The cortex of a store.
    #[must_use]
    pub fn new(store: Store) -> Cortex {
        Cortex { store }
    }

    /// The store.
    #[must_use]
    pub fn store(&self) -> &Store {
        &self.store
    }

    /// Makes a design and its main branch, as the app.
    pub async fn create_design(&self, new: &NewDesign) -> Result<Design, CoreError> {
        Ok(self
            .store
            .write(&Account::Service, async |tx| {
                let id: DesignId = tx
                    .query_one(
                        "INSERT INTO cortex.designs (name, engine, engine_version, flavor, comment) VALUES ($1, $2, $3, $4, $5) RETURNING id",
                        &[&new.name, &new.engine, &new.version, &new.flavor, &new.comment],
                    )
                    .await?
                    .get(0);
                let main: BranchId = tx
                    .query_one("INSERT INTO cortex.branches (design, name) VALUES ($1, 'main') RETURNING id", &[&id])
                    .await?
                    .get(0);
                Ok(Design {
                    id,
                    name: new.name.clone(),
                    engine: new.engine.clone(),
                    version: new.version.clone(),
                    flavor: new.flavor.clone(),
                    main,
                })
            })
            .await?)
    }

    /// Deletes a design and everything of it, its log included, as the app.
    pub async fn delete_design(&self, design: DesignId) -> Result<(), CoreError> {
        let n = self
            .store
            .write(&Account::Service, async |tx| {
                Ok(tx
                    .execute("DELETE FROM cortex.designs WHERE id = $1", &[&design])
                    .await?)
            })
            .await?;
        if n == 0 {
            return Err(CoreError::NotFound(format!("design {design}")));
        }
        Ok(())
    }

    /// Opens a turn on a branch, as the app or the agent; its parent is the branch's head. Refused with
    /// [`CoreError::TurnHeld`] while the design has another open turn.
    pub async fn open_turn(
        &self,
        by: &Account,
        design: DesignId,
        branch: BranchId,
        kind: TurnKind,
        author: &str,
        prompt: Option<&str>,
    ) -> Result<Turn, CoreError> {
        opener(by, "open a turn")?;
        let opened = self
            .store
            .write(by, async |tx| open(tx, design, branch, kind, author, prompt).await)
            .await;
        match opened {
            Err(StoreError::TurnHeld { .. }) => Err(self.held(design).await),
            other => Ok(other?),
        }
    }

    /// Runs one operation of an open turn as `account`: the operation's row, then `work`, in one transaction, every
    /// row it changes logged under the operation. An operation that touches an engine's own rows runs as that
    /// engine's plugin account; one of the shared model alone, as the app or the agent (decision plugin-operations).
    pub async fn operate<T>(
        &self,
        account: &Account,
        turn: &Turn,
        kind: &str,
        summary: &str,
        mut work: impl AsyncFnMut(&Transaction<'_>, OperationId) -> Result<T, StoreError>,
    ) -> Result<(OperationId, T), CoreError> {
        let (design, id) = (turn.design, turn.id);
        Ok(self
            .store
            .write(account, async |tx| {
                let operation = OperationId(begin_operation(tx, design.0, id.0, kind, summary).await?);
                let value = work(tx, operation).await?;
                Ok((operation, value))
            })
            .await?)
    }

    /// Commits an open turn: it is numbered in its design's commit order and the bell rings. Returns its number.
    pub async fn commit(&self, by: &Account, turn: &Turn, summary: Option<&str>) -> Result<i32, CoreError> {
        opener(by, "commit a turn")?;
        let id = turn.id;
        let seq = self
            .store
            .write(by, async |tx| {
                let row = tx
                    .query_opt(
                        "UPDATE cortex.turns SET state = 'committed', ended_at = now(), summary = coalesce($2, summary) \
                         WHERE id = $1 AND state = 'open' RETURNING seq",
                        &[&id, &summary],
                    )
                    .await?;
                Ok(row.map(|r| r.get::<_, i32>(0)))
            })
            .await?;
        seq.ok_or_else(|| CoreError::NotFound(format!("open turn {id}")))
    }

    /// Rejects an open turn that has no operation; a turn with operations has rows in the model, so it is committed
    /// and undone instead ([`CoreError::NotEmpty`]).
    pub async fn reject(&self, by: &Account, turn: &Turn) -> Result<(), CoreError> {
        opener(by, "reject a turn")?;
        let id = turn.id;
        let outcome = self
            .store
            .write(by, async |tx| {
                let ops: i64 = tx
                    .query_one("SELECT count(*) FROM cortex.operations WHERE turn = $1", &[&id])
                    .await?
                    .get(0);
                if ops > 0 {
                    return Ok(Some(false));
                }
                let n = tx
                    .execute(
                        "UPDATE cortex.turns SET state = 'rejected', ended_at = now() WHERE id = $1 AND state = 'open'",
                        &[&id],
                    )
                    .await?;
                Ok((n == 1).then_some(true))
            })
            .await?;
        match outcome {
            Some(true) => Ok(()),
            Some(false) => Err(CoreError::NotEmpty(id)),
            None => Err(CoreError::NotFound(format!("open turn {id}"))),
        }
    }

    /// Undoes a committed turn, as one transaction: an undo turn with one operation that applies the inverse of its
    /// row changes, newest first (cortex.undo), committed. Undoing an undo is a redo. Returns the undo turn.
    pub async fn undo(&self, by: &Account, branch: BranchId, target: &Turn, author: &str) -> Result<Turn, CoreError> {
        opener(by, "undo")?;
        let (design, target_id) = (target.design, target.id);
        let done = self
            .store
            .write(by, async |tx| {
                let turn = open(tx, design, branch, TurnKind::Undo, author, None).await?;
                begin_operation(tx, design.0, turn.id.0, "undo", &format!("undo turn {target_id}")).await?;
                tx.execute("SELECT cortex.undo($1)", &[&target_id]).await?;
                finish(tx, turn.id, &format!("undid turn {target_id}")).await
            })
            .await;
        match done {
            Err(StoreError::TurnHeld { .. }) => Err(self.held(design).await),
            other => Ok(other?),
        }
    }

    /// Restores a design to the model right after a committed turn, as one transaction: a restore turn that undoes,
    /// newest first, every turn after it that is still in effect, until none is. Returns the restore turn.
    pub async fn restore(&self, by: &Account, branch: BranchId, to: &Turn, author: &str) -> Result<Turn, CoreError> {
        opener(by, "restore")?;
        let design = to.design;
        let Some(to_seq) = to.seq else {
            return Err(CoreError::NotFound(format!("committed turn {}", to.id)));
        };
        let done = self
            .store
            .write(by, async |tx| {
                let turn = open(tx, design, branch, TurnKind::Restore, author, None).await?;
                // each undo may bring back turns an earlier undo had undone; the loop goes on until none after `to`
                // is in effect; every pass undoes one turn, and a design has finitely many
                for _ in 0..100_000 {
                    let next = tx
                        .query_opt(
                            "SELECT id FROM cortex.turns WHERE design = $1 AND state = 'committed' AND seq > $2 \
                             ORDER BY seq DESC LIMIT 1",
                            &[&design, &to_seq],
                        )
                        .await?;
                    let Some(next) = next else {
                        return finish(tx, turn.id, &format!("restored to turn {to_seq}")).await;
                    };
                    let undone: TurnId = next.get(0);
                    begin_operation(tx, design.0, turn.id.0, "undo", &format!("undo turn {undone}")).await?;
                    tx.execute("SELECT cortex.undo($1)", &[&undone]).await?;
                }
                Err(StoreError::Invalid("restore did not settle".into()))
            })
            .await;
        match done {
            Err(StoreError::TurnHeld { .. }) => Err(self.held(design).await),
            other => Ok(other?),
        }
    }

    /// Locks the design's current model as its next version: its newest committed turn and the model's hash. Refused
    /// while a turn is open.
    pub async fn lock_version(&self, design: DesignId, locked_by: &str) -> Result<LockedVersion, CoreError> {
        let locked = self
            .store
            .write(&Account::Service, async |tx| {
                let open: i64 = tx
                    .query_one("SELECT count(*) FROM cortex.turns WHERE design = $1 AND state = 'open'", &[&design])
                    .await?
                    .get(0);
                if open > 0 {
                    return Err(StoreError::Invalid(format!("the design {design} has an open turn: lock after it ends")));
                }
                let Some(head) = tx
                    .query_opt(
                        "SELECT id FROM cortex.turns WHERE design = $1 AND seq IS NOT NULL ORDER BY seq DESC LIMIT 1",
                        &[&design],
                    )
                    .await?
                else {
                    return Ok(None);
                };
                let turn: TurnId = head.get(0);
                let hash = model::read(tx, design).await?.hash();
                let row = tx
                    .query_one(
                        "INSERT INTO cortex.locked_versions (design, turn, number, hash, locked_by) \
                         VALUES ($1, $2, (SELECT coalesce(max(number), 0) + 1 FROM cortex.locked_versions WHERE design = $1), $3, $4) \
                         RETURNING id, number",
                        &[&design, &turn, &hash, &locked_by],
                    )
                    .await?;
                Ok(Some(LockedVersion { id: row.get(0), number: row.get(1), turn, hash }))
            })
            .await?;
        locked.ok_or_else(|| CoreError::NotFound(format!("a committed turn of design {design}")))
    }

    /// The design's whole model now, as the reader.
    pub async fn model(&self, design: DesignId) -> Result<Model, CoreError> {
        Ok(self
            .store
            .read(&Account::Reader, async |tx| model::read(tx, design).await)
            .await?)
    }

    /// A turn, as the reader.
    pub async fn turn(&self, id: TurnId) -> Result<Turn, CoreError> {
        let row = self
            .store
            .read(&Account::Reader, async |tx| {
                Ok(tx
                    .query_opt(&format!("SELECT {TURN} FROM cortex.turns WHERE id = $1"), &[&id])
                    .await?)
            })
            .await?;
        row.map(|r| Turn::from_row(&r))
            .ok_or_else(|| CoreError::NotFound(format!("turn {id}")))
    }

    /// Who holds a design's open turn: the error for a writer that was refused it.
    async fn held(&self, design: DesignId) -> CoreError {
        let holder = self
            .store
            .read(&Account::Reader, async |tx| {
                Ok(tx
                    .query_opt(
                        "SELECT id, author, kind, started_at::text FROM cortex.turns WHERE design = $1 AND state = 'open'",
                        &[&design],
                    )
                    .await?)
            })
            .await;
        match holder {
            Ok(Some(r)) => CoreError::TurnHeld {
                design,
                turn: r.get(0),
                author: r.get(1),
                kind: r.get(2),
                since: r.get(3),
            },
            Ok(None) => CoreError::Store(StoreError::TurnHeld {
                design: design.to_string(),
            }),
            Err(e) => CoreError::Store(e),
        }
    }
}

/// Only the app and the agent open, end and undo turns; a plugin adds its operations to theirs.
fn opener(by: &Account, what: &'static str) -> Result<(), CoreError> {
    match by {
        Account::Service | Account::Agent => Ok(()),
        other => Err(CoreError::NotAllowed {
            account: other.role(),
            what,
        }),
    }
}

/// Opens a turn in a transaction; its parent is the branch's head, the newest numbered turn of the branch.
async fn open(
    tx: &Transaction<'_>,
    design: DesignId,
    branch: BranchId,
    kind: TurnKind,
    author: &str,
    prompt: Option<&str>,
) -> Result<Turn, StoreError> {
    let row = tx
        .query_one(
            &format!(
                "INSERT INTO cortex.turns (design, branch, parent, kind, author, prompt) VALUES ($1, $2, \
                 (SELECT id FROM cortex.turns WHERE design = $1 AND branch = $2 AND seq IS NOT NULL ORDER BY seq DESC LIMIT 1), \
                 $3, $4, $5) RETURNING {TURN}"
            ),
            &[&design, &branch, &kind.as_str(), &author, &prompt],
        )
        .await?;
    Ok(Turn::from_row(&row))
}

/// Commits a turn in the transaction that made it.
async fn finish(tx: &Transaction<'_>, turn: TurnId, summary: &str) -> Result<Turn, StoreError> {
    let row = tx
        .query_one(
            &format!(
                "UPDATE cortex.turns SET state = 'committed', ended_at = now(), summary = $2 WHERE id = $1 RETURNING {TURN}"
            ),
            &[&turn, &summary],
        )
        .await?;
    Ok(Turn::from_row(&row))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_app_and_the_agent_hold_turns() {
        assert!(opener(&Account::Service, "x").is_ok());
        assert!(opener(&Account::Agent, "x").is_ok());
        assert!(opener(&Account::Reader, "x").is_err());
        assert!(opener(&Account::Plugin("engine_mysql".into()), "x").is_err());
    }
}
