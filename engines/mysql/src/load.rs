//! From the store's rows to a design. As the plugin's account, in one consistent snapshot, one query for each table of the
//! design's rows, read as typed rows; then maps by id over them. No string key is built: a row is found by the id of the
//! row it belongs to, and its children come in position order.

use std::collections::HashMap;

use schema_forge_store::{Store, StoreError};
use uuid::Uuid;

use crate::rows::{
    Accounts, ColumnOptions, Columns, Components, CompressionDictionaries, ConstraintColumns, Constraints, Databases,
    Dependencies, Events, IndexOptions, IndexPartOptions, IndexParts, Indexes, Instances, Libraries, LoadableFunctions,
    Namespaces, Objects, Partitionings, Partitions, Privileges, ResourceGroups, RoleGrants, RoutineParameters,
    Routines, Rows, Servers, SpatialReferenceSystems, TableOptions, Tablespaces, Triggers, Views,
};
use crate::store::account;

/// The place of each row of a table by its id.
pub type ById = HashMap<Uuid, usize>;
/// The places of the rows that belong to one row, by that row's id, in position order.
pub type Children = HashMap<Uuid, Vec<usize>>;

/// The places of rows by id: the maps a writer walks. Every value is an index into the vectors of [`Design::rows`].
#[derive(Clone, Debug, Default)]
pub struct Maps {
    /// A namespace.
    pub namespace: ById,
    /// An object.
    pub object: ById,
    /// A column.
    pub column: ById,
    /// The columns of an object, by the object's id.
    pub columns_of: Children,
    /// The indexes of an object.
    pub indexes_of: Children,
    /// The parts of an index, by the index's id.
    pub parts_of: Children,
    /// The constraints of an object.
    pub constraints_of: Children,
    /// The columns of a constraint, by the constraint's id.
    pub constraint_columns_of: Children,
    /// What an object uses, by the object's id.
    pub dependencies_of: Children,
    /// The engine row of a table, by the object's id.
    pub table: ById,
    /// The engine row of a database (a namespace), by the namespace's id.
    pub database: ById,
    /// The engine row of a column, by the column's id.
    pub column_options: ById,
    /// The engine row of an index, by the index's id.
    pub index_options: ById,
    /// The engine row of an index part, by the part's id.
    pub index_part_options: ById,
    /// The partitioning of a table, by the table's id.
    pub partitioning: ById,
    /// The partitions of a partitioning, by its id.
    pub partitions_of: Children,
    /// The engine row of a view, by the object's id.
    pub view: ById,
    /// The engine row of a routine, by the object's id.
    pub routine: ById,
    /// The engine row of a trigger, by the object's id.
    pub trigger: ById,
    /// The engine row of an event, by the object's id.
    pub event: ById,
    /// The engine row of a library, by the object's id.
    pub library: ById,
    /// The engine row of an account or role, by the object's id.
    pub account: ById,
    /// The engine row of a federated server, by the object's id.
    pub server: ById,
    /// The engine row of a loadable function, by the object's id.
    pub loadable_function: ById,
    /// The engine row of a component, by the object's id.
    pub component: ById,
    /// The engine row of a resource group, by the object's id.
    pub resource_group: ById,
    /// The engine row of a spatial reference system, by the object's id.
    pub spatial_reference_system: ById,
    /// The engine row of a tablespace, by the object's id.
    pub tablespace: ById,
    /// The engine row of a compression dictionary, by the object's id.
    pub compression_dictionary: ById,
}

/// A design as the store holds it: every table's rows, and the maps by id over them.
#[derive(Clone, Debug, Default)]
pub struct Design {
    /// Every table's rows, column-wise, as loaded.
    pub rows: Rows,
    /// The maps by id.
    pub maps: Maps,
}

/// The place of each id.
fn by_id(ids: &[Uuid]) -> ById {
    ids.iter().enumerate().map(|(place, id)| (*id, place)).collect()
}

/// The places of the rows of each owner, in position order (the order of the rows where there is no position).
fn children(owners: &[Uuid], positions: Option<&[i32]>) -> Children {
    let mut out: Children = HashMap::new();
    for (place, owner) in owners.iter().enumerate() {
        out.entry(*owner).or_default().push(place);
    }
    if let Some(positions) = positions {
        for places in out.values_mut() {
            places.sort_by_key(|&place| (positions[place], place));
        }
    }
    out
}

impl Maps {
    /// Builds every map over the loaded rows.
    #[must_use]
    pub fn of(rows: &Rows) -> Maps {
        Maps {
            namespace: by_id(&rows.namespaces.id),
            object: by_id(&rows.objects.id),
            column: by_id(&rows.columns.id),
            columns_of: children(&rows.columns.object, Some(&rows.columns.position)),
            indexes_of: children(&rows.indexes.object, Some(&rows.indexes.position)),
            parts_of: children(&rows.index_parts.index, Some(&rows.index_parts.position)),
            constraints_of: children(&rows.constraints.object, Some(&rows.constraints.position)),
            constraint_columns_of: children(
                &rows.constraint_columns.constraint,
                Some(&rows.constraint_columns.position),
            ),
            dependencies_of: children(&rows.dependencies.object, Some(&rows.dependencies.position)),
            table: by_id(&rows.tables.id),
            database: by_id(&rows.databases.id),
            column_options: by_id(&rows.column_options.id),
            index_options: by_id(&rows.index_options.id),
            index_part_options: by_id(&rows.index_part_options.id),
            partitioning: by_id(&rows.partitionings.id),
            partitions_of: children(&rows.partitions.partitioning, Some(&rows.partitions.position)),
            view: by_id(&rows.views.id),
            routine: by_id(&rows.routines.id),
            trigger: by_id(&rows.triggers.id),
            event: by_id(&rows.events.id),
            library: by_id(&rows.libraries.id),
            account: by_id(&rows.accounts.id),
            server: by_id(&rows.servers.id),
            loadable_function: by_id(&rows.loadable_functions.id),
            component: by_id(&rows.components.id),
            resource_group: by_id(&rows.resource_groups.id),
            spatial_reference_system: by_id(&rows.spatial_reference_systems.id),
            tablespace: by_id(&rows.tablespaces.id),
            compression_dictionary: by_id(&rows.compression_dictionaries.id),
        }
    }
}

/// Loads a design's rows as the plugin's account: one query for each table, all in one consistent snapshot.
pub async fn load(store: &Store, design: Uuid) -> Result<Design, StoreError> {
    let rows = store
        .read(&account(), async |tx| {
            let mut rows = Rows::default();
            macro_rules! fetch {
                ($($field:ident: $table:ty),+ $(,)?) => { $(
                    rows.$field = <$table>::from_rows(&tx.query(<$table>::select_sql().as_str(), &[&design]).await?)?;
                )+ };
            }
            fetch! {
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
            Ok(rows)
        })
        .await?;
    let maps = Maps::of(&rows);
    Ok(Design { rows, maps })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn children_come_in_position_order_under_their_owner() {
        let (a, b) = (Uuid::now_v7(), Uuid::now_v7());
        let mut rows = Rows::default();
        for (object, position) in [(a, 3), (b, 1), (a, 1), (a, 2)] {
            rows.columns.id.push(Uuid::now_v7());
            rows.columns.object.push(object);
            rows.columns.position.push(position);
        }
        let maps = children(&rows.columns.object, Some(&rows.columns.position));
        assert_eq!(maps[&a], vec![2, 3, 0]);
        assert_eq!(maps[&b], vec![1]);
    }

    #[test]
    fn a_row_is_found_by_its_id() {
        let ids = [Uuid::now_v7(), Uuid::now_v7()];
        let found = by_id(&ids);
        assert_eq!(found[&ids[1]], 1);
        assert_eq!(found.len(), 2);
    }
}
