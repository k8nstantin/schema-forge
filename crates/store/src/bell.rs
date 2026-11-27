//! The bell: every committed turn, as `schema_forge_turns` rings it (`cortex.notify_turn`: the design and its number in
//! the design's commit order). A notification is not durable, so the bell keeps the last number it gave per design
//! and reads what it missed (decision bell-catch-up): after its connection comes back, and whenever a number skips.
//! It listens on one connection of its own, outside the pools, as the reader.

use std::collections::HashMap;
use std::time::Duration;

use futures_util::StreamExt;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::mpsc;
use tokio_postgres::{AsyncMessage, Client, Connection, Notification};
use uuid::Uuid;

use crate::{Account, Accounts, Endpoint, StoreError, Tls};

/// What the bell gives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ring {
    /// A turn committed: the design and the turn's number in its commit order.
    Committed {
        /// The design.
        design: Uuid,
        /// The turn's number.
        seq: i32,
    },
    /// The bell's connection broke and came back; every turn committed meanwhile follows.
    Reconnected,
}

/// How the bell behaves.
#[derive(Clone, Debug)]
pub struct BellOptions {
    /// The first pause before connecting again.
    pub reconnect_first: Duration,
    /// The longest pause.
    pub reconnect_max: Duration,
    /// The name its connection gives the server.
    pub application: String,
}

impl Default for BellOptions {
    fn default() -> BellOptions {
        BellOptions {
            reconnect_first: Duration::from_millis(100),
            reconnect_max: Duration::from_secs(5),
            application: "schema-forge-bell".into(),
        }
    }
}

type Notes = mpsc::UnboundedReceiver<Result<Notification, tokio_postgres::Error>>;

/// A listening bell. Dropping it stops it.
pub struct Bell {
    rings: mpsc::UnboundedReceiver<Ring>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Bell {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Bell {
    /// Starts listening as `account` (the reader). It is listening when this returns: every turn committed afterwards
    /// is given, in each design's commit order.
    pub async fn listen(
        endpoint: &Endpoint,
        accounts: &Accounts,
        account: &Account,
        options: BellOptions,
    ) -> Result<Bell, StoreError> {
        let mut endpoint = endpoint.clone();
        endpoint.application.clone_from(&options.application);
        let config = endpoint.config(&account.role(), accounts.password(account)?);
        let role = account.role();
        let (client, notes) = connect(&config, endpoint.tls, &role).await?;
        client.batch_execute("LISTEN schema_forge_turns").await?;
        let last = heads(&client).await?;
        let (send, rings) = mpsc::unbounded_channel();
        let task = tokio::spawn(run(Listening {
            config,
            tls: endpoint.tls,
            role,
            options,
            client,
            notes,
            last,
            send,
        }));
        Ok(Bell { rings, task })
    }

    /// The next ring; `None` once the bell has stopped.
    pub async fn next(&mut self) -> Option<Ring> {
        self.rings.recv().await
    }
}

struct Listening {
    config: tokio_postgres::Config,
    tls: Tls,
    role: String,
    options: BellOptions,
    client: Client,
    notes: Notes,
    last: HashMap<Uuid, i32>,
    send: mpsc::UnboundedSender<Ring>,
}

async fn run(mut l: Listening) {
    loop {
        match l.notes.recv().await {
            Some(Ok(note)) => {
                let Some((design, seq)) = parse(note.payload()) else {
                    continue;
                };
                if catch_up(&l.client, &mut l.last, &l.send, Some((design, seq)))
                    .await
                    .is_err()
                {
                    continue;
                }
            }
            Some(Err(_)) | None => {
                if !reconnect(&mut l).await {
                    return;
                }
            }
        }
        if l.send.is_closed() {
            return;
        }
    }
}

/// Connects again until it can, listens, says so, and gives every turn committed while it was away.
async fn reconnect(l: &mut Listening) -> bool {
    let mut pause = l.options.reconnect_first;
    loop {
        tokio::time::sleep(pause).await;
        if l.send.is_closed() {
            return false;
        }
        if let Ok((client, notes)) = connect(&l.config, l.tls, &l.role).await
            && client.batch_execute("LISTEN schema_forge_turns").await.is_ok()
        {
            l.client = client;
            l.notes = notes;
            if l.send.send(Ring::Reconnected).is_err() {
                return false;
            }
            if catch_up(&l.client, &mut l.last, &l.send, None).await.is_ok() {
                return true;
            }
        }
        pause = (pause * 2).min(l.options.reconnect_max);
    }
}

/// Gives, in order, every committed turn after the last given: of one design up to and including `upto`, or of every
/// design when `upto` is `None`.
async fn catch_up(
    client: &Client,
    last: &mut HashMap<Uuid, i32>,
    send: &mpsc::UnboundedSender<Ring>,
    upto: Option<(Uuid, i32)>,
) -> Result<(), StoreError> {
    let rows: Vec<(Uuid, i32)> = if let Some((design, seq)) = upto {
        let after = last.get(&design).copied().unwrap_or(0);
        if seq <= after {
            return Ok(());
        }
        if seq == after + 1 {
            vec![(design, seq)]
        } else {
            client
                .query(
                    "SELECT design, seq FROM cortex.turns WHERE design = $1 AND seq > $2 AND seq <= $3 ORDER BY seq",
                    &[&design, &after, &seq],
                )
                .await?
                .iter()
                .map(|r| (r.get(0), r.get(1)))
                .collect()
        }
    } else {
        let (designs, seqs): (Vec<Uuid>, Vec<i32>) = last.iter().map(|(d, s)| (*d, *s)).unzip();
        client
            .query(
                "SELECT t.design, t.seq FROM cortex.turns t \
                 LEFT JOIN unnest($1::uuid[], $2::int4[]) AS k(design, seq) ON k.design = t.design \
                 WHERE t.seq > coalesce(k.seq, 0) ORDER BY t.design, t.seq",
                &[&designs, &seqs],
            )
            .await?
            .iter()
            .map(|r| (r.get(0), r.get(1)))
            .collect()
    };
    for (design, seq) in rows {
        last.insert(design, seq);
        if send.send(Ring::Committed { design, seq }).is_err() {
            break;
        }
    }
    Ok(())
}

/// Every design's newest number now: what the bell starts from.
async fn heads(client: &Client) -> Result<HashMap<Uuid, i32>, StoreError> {
    Ok(client
        .query(
            "SELECT design, max(seq) FROM cortex.turns WHERE seq IS NOT NULL GROUP BY design",
            &[],
        )
        .await?
        .iter()
        .map(|r| (r.get(0), r.get(1)))
        .collect())
}

/// `design:seq`, as `cortex.notify_turn` rings it.
fn parse(payload: &str) -> Option<(Uuid, i32)> {
    let (design, seq) = payload.split_once(':')?;
    Some((design.parse().ok()?, seq.parse().ok()?))
}

async fn connect(config: &tokio_postgres::Config, tls: Tls, role: &str) -> Result<(Client, Notes), StoreError> {
    let failed = |e: tokio_postgres::Error| StoreError::Connect {
        role: role.to_string(),
        reason: e.to_string(),
    };
    match tls {
        Tls::Disable => {
            let (client, connection) = config.connect(tokio_postgres::NoTls).await.map_err(failed)?;
            Ok((client, drive(connection)))
        }
        Tls::Require => {
            let (client, connection) = config.connect(Endpoint::connector()?).await.map_err(failed)?;
            Ok((client, drive(connection)))
        }
    }
}

/// Drives a connection and forwards its notifications; the channel closes when the connection does.
fn drive<S, T>(mut connection: Connection<S, T>) -> Notes
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    T: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (send, notes) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut messages = futures_util::stream::poll_fn(move |cx| connection.poll_message(cx));
        while let Some(message) = messages.next().await {
            match message {
                Ok(AsyncMessage::Notification(note)) => {
                    if send.send(Ok(note)).is_err() {
                        return;
                    }
                }
                Ok(_) => {}
                Err(e) => {
                    let _ = send.send(Err(e));
                    return;
                }
            }
        }
    });
    notes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_bells_payload() {
        let design = Uuid::now_v7();
        assert_eq!(parse(&format!("{design}:12")), Some((design, 12)));
        assert_eq!(parse("not:a:payload"), None);
        assert_eq!(parse("plain"), None);
    }
}
