//! Storing a design's rows in one operation. The read and the build come first and hold no transaction in the store; then
//! one write, as the plugin's own account, opens the operation and sends one `INSERT ... SELECT ... FROM unnest` for each
//! table that has rows, parents before children. The closure builds nothing, so a retry after a collision runs only the
//! inserts again.

use std::sync::Arc;
use std::time::Instant;

use schema_forge_engine::{EngineError, ImportReport, Source};
use schema_forge_store::{Account, Store, StoreError, ToSql, begin_operation};
use uuid::Uuid;

use crate::build::build;
use crate::read::{connect, snapshot};
use crate::rows::{
    Accounts, ColumnOptions, Columns, Components, CompressionDictionaries, ConstraintColumns, Constraints, Databases,
    Dependencies, Events, IndexOptions, IndexPartOptions, IndexParts, Indexes, Instances, Libraries, LoadableFunctions,
    Namespaces, Objects, Partitionings, Partitions, Privileges, ResourceGroups, RoleGrants, RoutineParameters,
    Routines, Rows, Servers, SpatialReferenceSystems, TableOptions, Tablespaces, Triggers, Views,
};

/// The plugin's own account in the store.
#[must_use]
pub fn account() -> Account {
    Account::Plugin("engine_mysql".to_string())
}

/// One statement to send: a table's rows, bound as arrays.
pub struct Statement {
    /// The table, schema-qualified.
    pub table: &'static str,
    /// The `INSERT ... SELECT ... FROM unnest(...)`.
    pub sql: String,
    /// The table's vectors of the rows, in the statement's order, bound as the statement's parameters.
    pub params: for<'r> fn(&'r Rows) -> Vec<&'r (dyn ToSql + Sync)>,
    /// How many rows the statement stores.
    pub rows: usize,
}

/// Every table that has rows, in the order they are stored: the cortex's parents before their children, then the
/// engine's own tables. A table whose columns differ in length is an error naming it: unnest would pad it with NULLs.
pub fn statements(rows: &Rows) -> Result<Vec<Statement>, EngineError> {
    let mut out = Vec::new();
    macro_rules! in_order {
        ($($field:ident: $table:ty),+ $(,)?) => { $(
            if let Some((column, n, first)) = rows.$field.uneven() {
                return Err(EngineError::Unsupported(format!(
                    "{} was built unevenly: its column {column} has {n} rows where the first has {first}",
                    <$table>::TABLE
                )));
            }
            if !rows.$field.is_empty() {
                out.push(Statement {
                    table: <$table>::TABLE,
                    sql: <$table>::insert_sql(),
                    params: |rows| rows.$field.params(),
                    rows: rows.$field.len(),
                });
            }
        )+ };
    }
    in_order! {
        namespaces: Namespaces,
        objects: Objects,
        columns: Columns,
        indexes: Indexes,
        index_parts: IndexParts,
        constraints: Constraints,
        constraint_columns: ConstraintColumns,
        dependencies: Dependencies,
        instances: Instances,
        databases: Databases,
        tables: TableOptions,
        column_options: ColumnOptions,
        index_options: IndexOptions,
        index_part_options: IndexPartOptions,
        partitionings: Partitionings,
        partitions: Partitions,
        views: Views,
        routines: Routines,
        routine_parameters: RoutineParameters,
        triggers: Triggers,
        events: Events,
        libraries: Libraries,
        accounts: Accounts,
        role_grants: RoleGrants,
        privileges: Privileges,
        servers: Servers,
        loadable_functions: LoadableFunctions,
        components: Components,
        resource_groups: ResourceGroups,
        spatial_reference_systems: SpatialReferenceSystems,
        tablespaces: Tablespaces,
        compression_dictionaries: CompressionDictionaries,
    }
    Ok(out)
}

/// The statements the store is sent for rows: one for the operation, one that names it to the history trigger, and one
/// for each table that has rows.
#[cfg(test)]
pub fn statement_count(rows: &Rows) -> Result<usize, EngineError> {
    Ok(statements(rows)?.len() + 2)
}

/// Stores every row in one operation of the open turn, as the plugin's account. Returns how many rows and statements.
pub async fn store(
    store: &Store,
    rows: Arc<Rows>,
    design: Uuid,
    turn: Uuid,
    summary: String,
) -> Result<(usize, usize), EngineError> {
    let plan = statements(&rows)?;
    let stored: usize = plan.iter().map(|s| s.rows).sum();
    let sent = plan.len() + 2;
    // The work owns what it binds, so it holds no borrow across its awaits and a retry runs only the inserts again.
    store
        .write(&account(), async move |tx| {
            begin_operation(tx, design, turn, "import", &summary).await?;
            for statement in &plan {
                tx.execute(statement.sql.as_str(), &(statement.params)(&rows))
                    .await
                    .map_err(|e| naming(StoreError::from(e), statement.table))?;
            }
            Ok(())
        })
        .await?;
    Ok((stored, sent))
}

/// A refusal of the store with the table it was storing named first; its code is kept, so a collision is still retried.
fn naming(error: StoreError, table: &str) -> StoreError {
    match error {
        StoreError::Refused {
            code,
            message,
            constraint,
            detail,
        } => StoreError::Refused {
            code,
            message: format!("storing {table}: {message}"),
            constraint,
            detail,
        },
        other => other,
    }
}

/// The host of a source address, for the operation's summary: what follows the `@`, or the address without its scheme.
fn host_of(url: &str) -> &str {
    let rest = url.strip_prefix("mysql://").unwrap_or(url);
    rest.rsplit_once('@').map_or(rest, |(_, host)| host)
}

/// Reads the source server, builds the design's rows, and stores them in one operation of the open turn.
pub async fn import(store_to: &Store, source: &Source, design: Uuid, turn: Uuid) -> Result<ImportReport, EngineError> {
    let started = Instant::now();
    let pool = connect(source)?;
    let read = snapshot(&pool, source.connections).await;
    // The pool is closed whatever the read said.
    let _ = pool.disconnect().await;
    let snap = read?;
    let rows = Arc::new(build(&snap, design)?);
    let read_took = started.elapsed();
    let summary = format!("imported {} from {}", snap.identity.full, host_of(&source.url));
    let began = Instant::now();
    let objects = rows.objects.len();
    let (stored, sent) = store(store_to, rows, design, turn, summary).await?;
    Ok(ImportReport {
        version: snap.identity.probe.version.clone(),
        flavor: snap.identity.probe.flavor.clone(),
        objects,
        rows: stored,
        statements: sent,
        read: read_took,
        stored: began.elapsed(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn some_rows() -> Rows {
        let mut rows = Rows::default();
        let id = Uuid::now_v7();
        for _ in 0..3 {
            rows.namespaces.id.push(id);
            rows.namespaces.design.push(id);
            rows.namespaces.parent.push(None);
            rows.namespaces.name.push("shop".to_string());
            rows.namespaces.position.push(1);
            rows.namespaces.comment.push(None);
        }
        rows
    }

    #[test]
    fn a_design_of_any_size_costs_at_most_its_tables_and_two_statements() {
        let rows = some_rows();
        let plan = statements(&rows).unwrap();
        assert_eq!(plan.len(), 1, "only the table with rows is sent");
        assert_eq!(plan[0].table, "cortex.namespaces");
        assert_eq!(plan[0].rows, 3);
        assert_eq!((plan[0].params)(&rows).len(), 6);
        assert_eq!(statement_count(&rows).unwrap(), 3);
        assert_eq!(statement_count(&Rows::default()).unwrap(), 2);
        // Never more than the 32 tables and the operation's two.
        assert!(statement_count(&rows).unwrap() <= 32 + 2);
    }

    #[test]
    fn a_table_built_unevenly_is_an_error_naming_it_never_padded_with_nulls() {
        let mut rows = some_rows();
        rows.namespaces.comment.pop();
        let error = statements(&rows).err().expect("an error").to_string();
        assert!(
            error.contains("cortex.namespaces") && error.contains("comment"),
            "{error}"
        );
    }

    fn env(name: &str) -> String {
        std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set: run python3 tools/app/all.py"))
    }

    /// Against the store `tools/app/all.py` makes: an import of 300 tables is a handful of statements, and the rows
    /// are in the design afterwards.
    #[tokio::test]
    async fn an_import_is_at_most_its_tables_plus_two_statements_however_many_objects() {
        use schema_forge_core::{Cortex, NewDesign, TurnKind};
        use schema_forge_store::{Accounts, Endpoint};

        use crate::sql::tests::Fixture;

        let endpoint = Endpoint::new(env("SF_TEST_HOST"), env("SF_TEST_PORT").parse().expect("SF_TEST_PORT"));
        let accounts = Accounts::read(std::path::Path::new(&env("SF_TEST_ACCOUNTS"))).expect("the accounts file");
        let cortex = Cortex::new(Store::new(endpoint, accounts));
        let design = cortex
            .create_design(&NewDesign {
                name: format!("t_{}", Uuid::now_v7().simple()),
                engine: "mysql".into(),
                version: "8.0".into(),
                flavor: "mysql".into(),
                comment: None,
            })
            .await
            .expect("a design");
        let turn = cortex
            .open_turn(
                &Account::Service,
                design.id,
                design.main,
                TurnKind::Import,
                "test",
                None,
            )
            .await
            .expect("a turn");
        let mut fixture = Fixture::of(design.id.0);
        for n in 0..300 {
            fixture.table(&format!("t{n}"));
        }
        let rows = Arc::new(fixture.rows);
        let (stored, sent) = store(
            cortex.store(),
            Arc::clone(&rows),
            design.id.0,
            turn.id.0,
            "imported 8.0 from test".into(),
        )
        .await
        .expect("the rows are stored");
        assert_eq!(statement_count(&rows).unwrap(), sent);
        assert!(sent <= 32 + 2, "{sent} statements");
        assert!(sent < 300, "not a statement for each object: {sent}");
        assert_eq!(stored, rows.namespaces.len() + rows.databases.len() + 4 * 300);
        let objects: i64 = cortex
            .store()
            .read(&account(), async |tx| {
                Ok(tx
                    .query_one("SELECT count(*) FROM cortex.objects WHERE design = $1", &[&design.id.0])
                    .await?
                    .get(0))
            })
            .await
            .expect("a read");
        assert_eq!(objects, 300);
        cortex
            .commit(&Account::Service, &turn, None)
            .await
            .expect("the turn commits");
    }

    #[test]
    fn parents_are_stored_before_children() {
        let mut rows = some_rows();
        rows.objects.id.push(Uuid::now_v7());
        rows.objects.design.push(Uuid::now_v7());
        rows.objects.engine.push("mysql".to_string());
        rows.objects.namespace.push(Uuid::now_v7());
        rows.objects.kind.push("table".to_string());
        rows.objects.name.push("t".to_string());
        rows.objects.signature.push(String::new());
        rows.objects.parent.push(None);
        rows.objects.position.push(1);
        rows.objects.comment.push(None);
        rows.objects.notes.push(None);
        let tables: Vec<_> = statements(&rows).unwrap().iter().map(|s| s.table).collect();
        assert_eq!(tables, ["cortex.namespaces", "cortex.objects"]);
    }

    #[test]
    fn the_host_of_a_source_is_named_without_its_user() {
        assert_eq!(host_of("mysql://reader@db.example:3307"), "db.example:3307");
        assert_eq!(host_of("mysql://127.0.0.1"), "127.0.0.1");
    }
}
