//! The store and the core against a real `schema_forge`: PostgreSQL 18 in a container with the cortex and
//! `engine_mysql` installed as the installer makes them, every account signing in with its own password. Run by
//! `python3 tools/app/all.py`, which makes the store and names it in `SF_TEST_*`. Each test works in a design of its
//! own, so the tests run side by side.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use schema_forge_core::{CoreError, Cortex, Design, NewDesign, Turn, TurnKind};
use schema_forge_store::{
    Account, Accounts, Bell, BellOptions, Endpoint, INSUFFICIENT_PRIVILEGE, Ring, Store, StoreError, begin_operation,
};
use uuid::Uuid;

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set: run python3 tools/app/all.py"))
}

fn endpoint() -> Endpoint {
    Endpoint::new(env("SF_TEST_HOST"), env("SF_TEST_PORT").parse().expect("SF_TEST_PORT"))
}

fn accounts() -> Accounts {
    Accounts::read(Path::new(&env("SF_TEST_ACCOUNTS"))).expect("the accounts file")
}

fn cortex() -> Cortex {
    Cortex::new(Store::new(endpoint(), accounts()))
}

fn mysql() -> Account {
    Account::Plugin("engine_mysql".into())
}

async fn design(c: &Cortex) -> Design {
    c.create_design(&NewDesign {
        name: format!("t_{}", Uuid::now_v7().simple()),
        engine: "mysql".into(),
        version: "8.0".into(),
        flavor: "mysql".into(),
        comment: None,
    })
    .await
    .expect("a design")
}

async fn turn(c: &Cortex, d: &Design, kind: TurnKind) -> Turn {
    c.open_turn(&Account::Service, d.id, d.main, kind, "test", None)
        .await
        .expect("a turn")
}

/// One operation adding a top-level namespace; returns its id.
async fn add_namespace(c: &Cortex, by: &Account, t: &Turn, name: &str, position: i32) -> Result<Uuid, CoreError> {
    let design = t.design;
    c.operate(by, t, "add_namespace", &format!("added {name}"), async |tx, _| {
        Ok(tx
            .query_one(
                "INSERT INTO cortex.namespaces (design, name, position) VALUES ($1, $2, $3::int4) RETURNING id",
                &[&design, &name, &position],
            )
            .await?
            .get(0))
    })
    .await
    .map(|(_, id)| id)
}

/// A committed turn that adds a namespace.
async fn committed(c: &Cortex, d: &Design, name: &str, position: i32) -> Turn {
    let t = turn(c, d, TurnKind::Edit).await;
    add_namespace(c, &Account::Service, &t, name, position)
        .await
        .expect("a namespace");
    c.commit(&Account::Service, &t, None).await.expect("committed");
    c.turn(t.id).await.expect("the turn")
}

async fn count(c: &Cortex, sql: &str, design: &Design) -> i64 {
    let id = design.id;
    c.store()
        .read(&Account::Reader, async |tx| {
            Ok(tx.query_one(sql, &[&id]).await?.get::<_, i64>(0))
        })
        .await
        .expect("a count")
}

fn code(e: &CoreError) -> Option<&str> {
    match e {
        CoreError::Store(s) => s.code(),
        _ => None,
    }
}

#[tokio::test]
async fn a_turn_commits_with_its_number() {
    let c = cortex();
    let d = design(&c).await;
    let t = turn(&c, &d, TurnKind::Import).await;
    assert_eq!(t.state, "open");
    add_namespace(&c, &Account::Service, &t, "shop", 1).await.unwrap();
    assert_eq!(c.commit(&Account::Service, &t, Some("read shop")).await.unwrap(), 1);
    let second = committed(&c, &d, "sales", 2).await;
    assert_eq!(second.seq, Some(2));
    assert_eq!(
        count(&c, "SELECT count(*) FROM cortex.row_changes WHERE design = $1", &d).await,
        2
    );
}

#[tokio::test]
async fn a_second_open_turn_is_refused_and_names_who_holds_it() {
    let c = cortex();
    let d = design(&c).await;
    let first = turn(&c, &d, TurnKind::Edit).await;
    let refused = c
        .open_turn(
            &Account::Agent,
            d.id,
            d.main,
            TurnKind::Agent,
            "agent",
            Some("add a table"),
        )
        .await;
    match refused {
        Err(CoreError::TurnHeld { turn, author, .. }) => {
            assert_eq!(turn, first.id);
            assert_eq!(author, "test");
        }
        other => panic!("expected the design held, got {other:?}"),
    }
    c.reject(&Account::Service, &first).await.unwrap();
    turn(&c, &d, TurnKind::Edit).await;
}

#[tokio::test]
async fn an_operation_failing_midway_leaves_nothing() {
    let c = cortex();
    let d = design(&c).await;
    let t = turn(&c, &d, TurnKind::Edit).await;
    let design = d.id;
    let failed = c
        .operate(&Account::Service, &t, "add_table", "added a table of no kind", async |tx, _| {
            let ns: Uuid = tx
                .query_one(
                    "INSERT INTO cortex.namespaces (design, name, position) VALUES ($1, 'shop', 1) RETURNING id",
                    &[&design],
                )
                .await?
                .get(0);
            tx.execute(
                "INSERT INTO cortex.objects (design, engine, namespace, kind, name, position) VALUES ($1, 'mysql', $2, 'no_such_kind', 't', 1)",
                &[&design, &ns],
            )
            .await?;
            Ok(())
        })
        .await;
    assert_eq!(failed.as_ref().err().and_then(code), Some("23503"), "{failed:?}");
    assert_eq!(
        count(&c, "SELECT count(*) FROM cortex.namespaces WHERE design = $1", &d).await,
        0
    );
    assert_eq!(
        count(&c, "SELECT count(*) FROM cortex.operations WHERE design = $1", &d).await,
        0
    );
    assert_eq!(
        count(&c, "SELECT count(*) FROM cortex.row_changes WHERE design = $1", &d).await,
        0
    );
    c.reject(&Account::Service, &t).await.unwrap();
}

#[tokio::test]
async fn the_operation_never_outlives_its_transaction_on_a_pooled_connection() {
    // one connection, so the write after the operation gets the very connection the operation used
    let c = Cortex::new(Store::new(endpoint(), accounts()).with_pool_size(1));
    let d = design(&c).await;
    let t = turn(&c, &d, TurnKind::Edit).await;
    add_namespace(&c, &Account::Service, &t, "shop", 1).await.unwrap();
    let design = d.id;
    let outside = c
        .store()
        .write(&Account::Service, async |tx| {
            tx.execute(
                "INSERT INTO cortex.namespaces (design, name, position) VALUES ($1, 'stray', 2)",
                &[&design],
            )
            .await?;
            Ok(())
        })
        .await;
    match outside {
        Err(StoreError::Refused { code, message, .. }) => {
            assert_eq!(code, INSUFFICIENT_PRIVILEGE);
            assert!(message.contains("outside an operation"), "{message}");
        }
        other => panic!("a change outside an operation must be refused, got {other:?}"),
    }
    c.commit(&Account::Service, &t, None).await.unwrap();
}

#[tokio::test]
async fn two_writers_at_once_are_retried_and_both_land() {
    let c = cortex();
    let d = design(&c).await;
    let t = turn(&c, &d, TurnKind::Edit).await;
    let gate = tokio::sync::Barrier::new(2);
    let writer = |name: &'static str| {
        let (c, t, gate) = (&c, &t, &gate);
        async move {
            let first = AtomicBool::new(true);
            c.store()
                .write(&Account::Service, async |tx| {
                    // both start together the first time, so they collide; a retry runs alone
                    if first.swap(false, Ordering::SeqCst) {
                        gate.wait().await;
                    }
                    begin_operation(tx, t.design.0, t.id.0, "add_namespace", name).await?;
                    tx.execute(
                        "INSERT INTO cortex.namespaces (design, name, position) \
                         SELECT $1, $2, coalesce(max(position), 0) + 1 FROM cortex.namespaces WHERE design = $1 AND parent IS NULL",
                        &[&t.design, &name],
                    )
                    .await?;
                    Ok(())
                })
                .await
        }
    };
    let (left, right) = tokio::join!(writer("left"), writer("right"));
    left.unwrap();
    right.unwrap();
    assert!(c.store().retries() >= 1, "the two writers should have collided");
    assert_eq!(
        count(
            &c,
            "SELECT count(DISTINCT position) FROM cortex.namespaces WHERE design = $1",
            &d
        )
        .await,
        2
    );
    assert_eq!(
        count(
            &c,
            "SELECT count(DISTINCT position) FROM cortex.operations WHERE design = $1",
            &d
        )
        .await,
        2
    );
    c.commit(&Account::Service, &t, None).await.unwrap();
}

#[tokio::test]
async fn a_plugin_writes_its_operation_whole() {
    let c = cortex();
    let d = design(&c).await;
    let t = turn(&c, &d, TurnKind::Import).await;
    let design = d.id;
    let table = |name: &'static str, reuse: Option<Uuid>| {
        async move |tx: &schema_forge_store::Transaction<'_>, _| {
            let ns: Uuid = match tx
                .query_opt(
                    "SELECT id FROM cortex.namespaces WHERE design = $1 AND name = 'shop'",
                    &[&design],
                )
                .await?
            {
                Some(row) => row.get(0),
                None => tx
                    .query_one(
                        "INSERT INTO cortex.namespaces (design, name, position) VALUES ($1, 'shop', 1) RETURNING id",
                        &[&design],
                    )
                    .await?
                    .get(0),
            };
            let object: Uuid = tx
                .query_one(
                    "INSERT INTO cortex.objects (design, engine, namespace, kind, name, position) \
                     VALUES ($1, 'mysql', $2, 'table', $3, (SELECT coalesce(max(position), 0) + 1 FROM cortex.objects WHERE namespace = $2)) RETURNING id",
                    &[&design, &ns, &name],
                )
                .await?
                .get(0);
            tx.execute(
                "INSERT INTO engine_mysql.tables (id, design, engine, \"collation\") VALUES ($1, $2, 'InnoDB', 'utf8mb4_0900_ai_ci')",
                &[&reuse.unwrap_or(object), &design],
            )
            .await?;
            Ok(object)
        }
    };
    let (_, orders) = c
        .operate(&mysql(), &t, "add_table", "added orders", table("orders", None))
        .await
        .unwrap();
    assert_eq!(
        count(&c, "SELECT count(*) FROM engine_mysql.tables WHERE design = $1", &d).await,
        1
    );
    assert_eq!(
        count(&c, "SELECT count(*) FROM cortex.row_changes WHERE design = $1", &d).await,
        3
    );
    // the second writes its object, then fails on its engine row: neither stays
    let failed = c
        .operate(&mysql(), &t, "add_table", "added lines", table("lines", Some(orders)))
        .await;
    assert_eq!(failed.as_ref().err().and_then(code), Some("23505"), "{failed:?}");
    assert_eq!(
        count(&c, "SELECT count(*) FROM cortex.objects WHERE design = $1", &d).await,
        1
    );
    assert_eq!(
        count(&c, "SELECT count(*) FROM cortex.operations WHERE design = $1", &d).await,
        1
    );
    c.commit(&Account::Service, &t, None).await.unwrap();
}

#[tokio::test]
async fn each_account_is_refused_what_is_not_its_work() {
    let c = cortex();
    let d = design(&c).await;
    let design = d.id;
    let reader = c
        .store()
        .write(&Account::Reader, async |tx| {
            tx.execute(
                "INSERT INTO cortex.namespaces (design, name, position) VALUES ($1, 'x', 1)",
                &[&design],
            )
            .await?;
            Ok(())
        })
        .await;
    assert_eq!(
        reader.err().as_ref().and_then(StoreError::code),
        Some(INSUFFICIENT_PRIVILEGE)
    );
    let agent = c
        .store()
        .write(&Account::Agent, async |tx| {
            tx.execute(
                "INSERT INTO cortex.designs (name, engine, engine_version, flavor) VALUES ('by_agent', 'mysql', '8.0', 'mysql')",
                &[],
            )
            .await?;
            Ok(())
        })
        .await;
    assert_eq!(
        agent.err().as_ref().and_then(StoreError::code),
        Some(INSUFFICIENT_PRIVILEGE)
    );
    let branch = d.main;
    let plugin = c
        .store()
        .write(&mysql(), async |tx| {
            tx.execute(
                "INSERT INTO cortex.turns (design, branch, kind, author) VALUES ($1, $2, 'edit', 'plugin')",
                &[&design, &branch],
            )
            .await?;
            Ok(())
        })
        .await;
    assert_eq!(
        plugin.err().as_ref().and_then(StoreError::code),
        Some(INSUFFICIENT_PRIVILEGE)
    );
    assert!(matches!(
        c.open_turn(&mysql(), d.id, d.main, TurnKind::Edit, "plugin", None)
            .await,
        Err(CoreError::NotAllowed { .. })
    ));
}

#[tokio::test]
async fn a_turn_with_operations_is_not_rejected() {
    let c = cortex();
    let d = design(&c).await;
    let t = turn(&c, &d, TurnKind::Edit).await;
    add_namespace(&c, &Account::Service, &t, "shop", 1).await.unwrap();
    assert!(matches!(c.reject(&Account::Service, &t).await, Err(CoreError::NotEmpty(id)) if id == t.id));
    c.commit(&Account::Service, &t, None).await.unwrap();
}

#[tokio::test]
async fn undo_is_exact_and_undoing_it_is_a_redo() {
    let c = cortex();
    let d = design(&c).await;
    let empty = c.model(d.id).await.unwrap().hash();
    let t1 = committed(&c, &d, "shop", 1).await;
    let after1 = c.model(d.id).await.unwrap().hash();
    let t2 = committed(&c, &d, "sales", 2).await;
    let after2 = c.model(d.id).await.unwrap().hash();
    assert_ne!(after1, after2);
    let u = c.undo(&Account::Service, d.main, &t2, "test").await.unwrap();
    assert_eq!(c.model(d.id).await.unwrap().hash(), after1);
    assert_eq!(c.turn(t2.id).await.unwrap().state, "undone");
    let redo = c
        .undo(&Account::Agent, d.main, &c.turn(u.id).await.unwrap(), "agent")
        .await
        .unwrap();
    assert_eq!(c.model(d.id).await.unwrap().hash(), after2);
    assert_eq!(c.turn(t2.id).await.unwrap().state, "committed");
    assert_eq!(c.turn(u.id).await.unwrap().state, "undone");
    assert_eq!(c.turn(redo.id).await.unwrap().state, "committed");
    c.undo(&Account::Service, d.main, &c.turn(redo.id).await.unwrap(), "test")
        .await
        .unwrap();
    c.undo(&Account::Service, d.main, &c.turn(t1.id).await.unwrap(), "test")
        .await
        .unwrap();
    assert_eq!(c.model(d.id).await.unwrap().hash(), empty);
}

#[tokio::test]
async fn restore_comes_back_exactly_across_undos_and_restores() {
    let c = cortex();
    let d = design(&c).await;
    let t1 = committed(&c, &d, "shop", 1).await;
    let after1 = c.model(d.id).await.unwrap().hash();
    committed(&c, &d, "sales", 2).await;
    let t3 = committed(&c, &d, "stock", 3).await;
    let after3 = c.model(d.id).await.unwrap().hash();
    let u = c.undo(&Account::Service, d.main, &t3, "test").await.unwrap();
    let after_u = c.model(d.id).await.unwrap().hash();
    // restore to turn 1: the undo, turn 3 it brings back, and turn 2 all undone
    let r1 = c.restore(&Account::Service, d.main, &t1, "test").await.unwrap();
    assert_eq!(c.model(d.id).await.unwrap().hash(), after1);
    // undoing the restore brings back exactly what it undid: turn 2, and turn 3 still undone by the undo
    c.undo(&Account::Service, d.main, &c.turn(r1.id).await.unwrap(), "test")
        .await
        .unwrap();
    assert_eq!(c.model(d.id).await.unwrap().hash(), after_u);
    assert_eq!(c.turn(t3.id).await.unwrap().state, "undone");
    assert_eq!(c.turn(u.id).await.unwrap().state, "committed");
    // and a restore to turn 3 brings turn 3 back
    c.restore(&Account::Service, d.main, &c.turn(t3.id).await.unwrap(), "test")
        .await
        .unwrap();
    assert_eq!(c.model(d.id).await.unwrap().hash(), after3);
}

#[tokio::test]
async fn a_locked_version_holds_the_models_hash() {
    let c = cortex();
    let d = design(&c).await;
    let t = committed(&c, &d, "shop", 1).await;
    let v = c.lock_version(d.id, "test").await.unwrap();
    assert_eq!((v.number, v.turn), (1, t.id));
    assert_eq!(v.hash, c.model(d.id).await.unwrap().hash());
    let open = turn(&c, &d, TurnKind::Edit).await;
    assert!(
        c.lock_version(d.id, "test").await.is_err(),
        "no lock while a turn is open"
    );
    c.reject(&Account::Service, &open).await.unwrap();
    assert_eq!(c.lock_version(d.id, "test").await.unwrap().number, 2);
}

/// The bell's next ring of one design, skipping the other tests' designs.
async fn ring_of(bell: &mut Bell, design: Uuid) -> Ring {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            match bell.next().await.expect("the bell stopped") {
                Ring::Committed { design: d, .. } if d != design => {}
                ring => return ring,
            }
        }
    })
    .await
    .expect("no ring within 20 s")
}

#[tokio::test]
async fn the_bell_rings_every_commit() {
    let c = cortex();
    let mut bell = Bell::listen(&endpoint(), &accounts(), &Account::Reader, BellOptions::default())
        .await
        .unwrap();
    let d = design(&c).await;
    committed(&c, &d, "shop", 1).await;
    committed(&c, &d, "sales", 2).await;
    assert_eq!(
        ring_of(&mut bell, d.id.0).await,
        Ring::Committed { design: d.id.0, seq: 1 }
    );
    assert_eq!(
        ring_of(&mut bell, d.id.0).await,
        Ring::Committed { design: d.id.0, seq: 2 }
    );
}

#[tokio::test]
async fn the_bell_catches_up_after_its_connection_is_killed() {
    let c = cortex();
    let name = format!("bell-test-{}", Uuid::now_v7().simple());
    let options = BellOptions {
        reconnect_first: Duration::from_secs(2),
        application: name.clone(),
        ..BellOptions::default()
    };
    let mut bell = Bell::listen(&endpoint(), &accounts(), &Account::Reader, options)
        .await
        .unwrap();
    let d = design(&c).await;
    committed(&c, &d, "shop", 1).await;
    assert_eq!(
        ring_of(&mut bell, d.id.0).await,
        Ring::Committed { design: d.id.0, seq: 1 }
    );
    // kill its connection, then commit while it is away (it waits 2 s before coming back)
    let killed = std::process::Command::new("docker")
        .args([
            "exec",
            &env("SF_TEST_CONTAINER"),
            "psql",
            "-U",
            "postgres",
            "-d",
            "schema_forge",
            "-Atc",
        ])
        .arg(format!(
            "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE application_name = '{name}'"
        ))
        .output()
        .expect("docker exec");
    assert_eq!(
        String::from_utf8_lossy(&killed.stdout).trim(),
        "1",
        "{}",
        String::from_utf8_lossy(&killed.stderr)
    );
    committed(&c, &d, "sales", 2).await;
    committed(&c, &d, "stock", 3).await;
    assert_eq!(ring_of(&mut bell, d.id.0).await, Ring::Reconnected);
    assert_eq!(
        ring_of(&mut bell, d.id.0).await,
        Ring::Committed { design: d.id.0, seq: 2 }
    );
    assert_eq!(
        ring_of(&mut bell, d.id.0).await,
        Ring::Committed { design: d.id.0, seq: 3 }
    );
}
