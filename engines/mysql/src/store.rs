//! Storing a design's rows in one operation. The read and the build come first and hold no transaction in the store; then
//! one write, as the plugin's own account, opens the operation and sends one `INSERT ... SELECT ... FROM unnest` for each
//! table that has rows, parents before children. The closure builds nothing, so a retry after a collision runs only the
//! inserts again.

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
pub struct Statement<'a> {
    /// The table, schema-qualified.
    pub table: &'static str,
    /// The `INSERT ... SELECT ... FROM unnest(...)`.
    pub sql: String,
    /// The table's vectors, in the statement's order.
    pub params: Vec<&'a (dyn ToSql + Sync)>,
    /// How many rows the statement stores.
    pub rows: usize,
}

/// Every table that has rows, in the order they are stored: the cortex's parents before their children, then the
/// engine's own tables.
#[must_use]
pub fn statements(rows: &Rows) -> Vec<Statement<'_>> {
    let mut out = Vec::new();
    macro_rules! in_order {
        ($($field:ident: $table:ty),+ $(,)?) => { $(
            if !rows.$field.is_empty() {
                out.push(Statement {
                    table: <$table>::TABLE,
                    sql: <$table>::insert_sql(),
                    params: rows.$field.params(),
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
    out
}

/// The statements the store is sent for rows: one for the operation, one that names it to the history trigger, and one
/// for each table that has rows.
#[must_use]
pub fn statement_count(rows: &Rows) -> usize {
    statements(rows).len() + 2
}

/// Stores every row in one operation of the open turn, as the plugin's account. Returns how many rows and statements.
pub async fn store(
    store: &Store,
    rows: &Rows,
    design: Uuid,
    turn: Uuid,
    summary: &str,
) -> Result<(usize, usize), StoreError> {
    let plan = statements(rows);
    let stored: usize = plan.iter().map(|s| s.rows).sum();
    let sent = plan.len() + 2;
    store
        .write(&account(), async |tx| {
            begin_operation(tx, design, turn, "import", summary).await?;
            for statement in &plan {
                tx.execute(statement.sql.as_str(), &statement.params).await?;
            }
            Ok(())
        })
        .await?;
    Ok((stored, sent))
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
    let rows = build(&snap, design)?;
    let read_took = started.elapsed();
    let summary = format!("imported {} from {}", snap.identity.full, host_of(&source.url));
    let began = Instant::now();
    let (stored, sent) = store(store_to, &rows, design, turn, &summary).await?;
    Ok(ImportReport {
        version: snap.identity.probe.version.clone(),
        flavor: snap.identity.probe.flavor.clone(),
        objects: rows.objects.len(),
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
        let plan = statements(&rows);
        assert_eq!(plan.len(), 1, "only the table with rows is sent");
        assert_eq!(plan[0].table, "cortex.namespaces");
        assert_eq!(plan[0].rows, 3);
        assert_eq!(plan[0].params.len(), 6);
        assert_eq!(statement_count(&rows), 3);
        assert!(statement_count(&Rows::default()) == 2);
        // Never more than the 32 tables and the operation's two.
        assert!(statement_count(&rows) <= 32 + 2);
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
        let tables: Vec<_> = statements(&rows).iter().map(|s| s.table).collect();
        assert_eq!(tables, ["cortex.namespaces", "cortex.objects"]);
    }

    #[test]
    fn the_host_of_a_source_is_named_without_its_user() {
        assert_eq!(host_of("mysql://reader@db.example:3307"), "db.example:3307");
        assert_eq!(host_of("mysql://127.0.0.1"), "127.0.0.1");
    }
}
