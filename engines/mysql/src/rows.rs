//! The store's rows, column-wise: for each destination table one struct of vectors, one vector per column, in the table's
//! column order. A table is stored with one statement, `INSERT ... SELECT ... FROM unnest($1::t1[], ...)`, so a design of
//! any size is as many statements as it has tables. A column the mapping leaves unfilled is not in its struct: the
//! table's own default fills it.

use schema_forge_store::{Row, StoreError, ToSql};
use uuid::Uuid;

/// The cast a column declares, or none.
macro_rules! cast_of {
    () => {
        None
    };
    ($cast:literal) => {
        Some($cast)
    };
}

/// One struct of column vectors per destination table. Each column is written
/// `name: RustType = "postgres type" [=> "cast in the select list"]`.
macro_rules! tables {
    ($( $name:ident = $table:literal { $( $col:ident : $ty:ty = $pg:literal $(=> $cast:literal)? ),+ $(,)? } )+) => { $(
        #[doc = concat!("The rows of `", $table, "`, one vector per column.")]
        #[derive(Clone, Debug, Default)]
        pub struct $name {
            $(
                #[doc = concat!("`", stringify!($col), "`.")]
                pub $col: Vec<$ty>,
            )+
        }

        impl $name {
            /// The table, schema-qualified.
            pub const TABLE: &'static str = $table;

            /// How many rows.
            #[must_use]
            pub fn len(&self) -> usize {
                [ $( self.$col.len() ),+ ][0]
            }

            /// Whether there are no rows.
            #[must_use]
            pub fn is_empty(&self) -> bool {
                self.len() == 0
            }

            /// The one statement that stores every row: the vectors are bound as arrays and unnested.
            #[must_use]
            pub fn insert_sql() -> String {
                let columns: &[(&str, &str, Option<&str>)] = &[ $( (
                    stringify!($col).trim_start_matches("r#"),
                    $pg,
                    cast_of!($($cast)?),
                ) ),+ ];
                let names: Vec<String> = columns.iter().map(|(n, _, _)| format!("\"{n}\"")).collect();
                let selected: Vec<String> = columns
                    .iter()
                    .map(|(n, _, cast)| match cast {
                        Some(cast) => format!("u.\"{n}\"::{cast}"),
                        None => format!("u.\"{n}\""),
                    })
                    .collect();
                let bound: Vec<String> = columns
                    .iter()
                    .enumerate()
                    .map(|(i, (_, pg, _))| format!("${}::{pg}[]", i + 1))
                    .collect();
                format!(
                    "INSERT INTO {} ({}) SELECT {} FROM unnest({}) AS u({})",
                    $table,
                    names.join(", "),
                    selected.join(", "),
                    bound.join(", "),
                    names.join(", "),
                )
            }

            /// The vectors, in the statement's order, as its parameters.
            #[must_use]
            pub fn params(&self) -> Vec<&(dyn ToSql + Sync)> {
                vec![ $( &self.$col as &(dyn ToSql + Sync) ),+ ]
            }

            /// The one query that loads a design's rows of the table, `$1` the design: a column stored under a cast is
            /// cast back to the type it is bound as.
            #[must_use]
            pub fn select_sql() -> String {
                let columns: &[(&str, &str, Option<&str>)] = &[ $( (
                    stringify!($col).trim_start_matches("r#"),
                    $pg,
                    cast_of!($($cast)?),
                ) ),+ ];
                let selected: Vec<String> = columns
                    .iter()
                    .map(|(n, pg, cast)| match cast {
                        Some(_) => format!("\"{n}\"::{pg} AS \"{n}\""),
                        None => format!("\"{n}\""),
                    })
                    .collect();
                format!("SELECT {} FROM {} WHERE design = $1 ORDER BY id", selected.join(", "), $table)
            }

            /// The rows a `select_sql` query gave, as vectors, each column read by its name.
            pub fn from_rows(rows: &[Row]) -> Result<Self, StoreError> {
                let mut out = Self::default();
                for row in rows {
                    $( out.$col.push(row.try_get::<_, $ty>(stringify!($col).trim_start_matches("r#"))?); )+
                }
                Ok(out)
            }
        }
    )+ };
}

tables! {
    Namespaces = "cortex.namespaces" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        parent: Option<Uuid> = "uuid",
        name: String = "text",
        position: i32 = "int4" => "numeric",
        comment: Option<String> = "text",
    }
    Objects = "cortex.objects" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        engine: String = "text",
        namespace: Uuid = "uuid",
        kind: String = "text",
        name: String = "text",
        signature: String = "text",
        parent: Option<Uuid> = "uuid",
        position: i32 = "int4" => "numeric",
        comment: Option<String> = "text",
        notes: Option<String> = "text",
    }
    Columns = "cortex.columns" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        object: Uuid = "uuid",
        position: i32 = "int4",
        name: String = "text",
        r#type: String = "text",
        nullable: bool = "bool",
        default_value: Option<String> = "text",
        generated_expression: Option<String> = "text",
        generated_stored: Option<bool> = "bool",
        collation: Option<String> = "text",
        comment: Option<String> = "text",
    }
    Indexes = "cortex.indexes" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        object: Uuid = "uuid",
        position: i32 = "int4",
        name: String = "text",
        unique: bool = "bool",
        method: Option<String> = "text",
        condition: Option<String> = "text",
        comment: Option<String> = "text",
    }
    IndexParts = "cortex.index_parts" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        index: Uuid = "uuid",
        position: i32 = "int4",
        column: Option<Uuid> = "uuid",
        expression: Option<String> = "text",
        descending: bool = "bool",
        included: bool = "bool",
    }
    Constraints = "cortex.constraints" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        object: Uuid = "uuid",
        position: i32 = "int4",
        name: Option<String> = "text",
        kind: String = "text",
        expression: Option<String> = "text",
        to_object: Option<Uuid> = "uuid",
        on_delete: Option<String> = "text",
        on_update: Option<String> = "text",
        enforced: bool = "bool",
        deferrable: bool = "bool",
        initially_deferred: bool = "bool",
    }
    ConstraintColumns = "cortex.constraint_columns" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        constraint: Uuid = "uuid",
        position: i32 = "int4",
        column: Uuid = "uuid",
        to_column: Option<Uuid> = "uuid",
    }
    Dependencies = "cortex.dependencies" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        object: Uuid = "uuid",
        uses: Uuid = "uuid",
        r#as: String = "text",
        position: i32 = "int4",
    }
    Instances = "engine_mysql.instances" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        version: String = "text",
        character_set: String = "text",
        collation: String = "text",
        lower_case_table_names: i32 = "int4",
        sql_mode: String = "text",
    }
    Databases = "engine_mysql.databases" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        character_set: String = "text",
        collation: String = "text",
        encryption: Option<bool> = "bool",
        read_only: Option<bool> = "bool",
    }
    TableOptions = "engine_mysql.tables" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        engine: String = "text",
        collation: String = "text",
        row_format: Option<String> = "text",
        auto_increment: Option<i64> = "int8",
        avg_row_length: Option<i64> = "int8",
        min_rows: Option<i64> = "int8",
        max_rows: Option<i64> = "int8",
        pack_keys: Option<String> = "text",
        checksum: Option<bool> = "bool",
        delay_key_write: Option<bool> = "bool",
        key_block_size: Option<i32> = "int4",
        stats_persistent: Option<String> = "text",
        stats_auto_recalc: Option<String> = "text",
        stats_sample_pages: Option<String> = "text",
        compression: Option<String> = "text",
        encryption: Option<bool> = "bool",
        tablespace: Option<String> = "text",
        storage: Option<String> = "text",
        data_directory: Option<String> = "text",
        index_directory: Option<String> = "text",
        autoextend_size: Option<String> = "text",
        engine_attribute: Option<String> = "text",
        secondary_engine: Option<String> = "text",
        secondary_engine_attribute: Option<String> = "text",
        insert_method: Option<String> = "text",
        connection: Option<String> = "text",
    }
    ColumnOptions = "engine_mysql.columns" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        character_set: Option<String> = "text",
        default_is_expression: bool = "bool",
        on_update: Option<String> = "text",
        auto_increment: bool = "bool",
        invisible: bool = "bool",
        srid: Option<i32> = "int4",
        column_format: Option<String> = "text",
        storage: Option<String> = "text",
        compression_dictionary: Option<Uuid> = "uuid",
        engine_attribute: Option<String> = "text",
        secondary_engine_attribute: Option<String> = "text",
    }
    IndexOptions = "engine_mysql.indexes" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        kind: String = "text",
        parser: Option<String> = "text",
        key_block_size: Option<i32> = "int4",
        invisible: bool = "bool",
        engine_attribute: Option<String> = "text",
        secondary_engine_attribute: Option<String> = "text",
    }
    IndexPartOptions = "engine_mysql.index_parts" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        prefix_length: i32 = "int4",
    }
    Partitionings = "engine_mysql.partitionings" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        method: String = "text",
        expression: Option<String> = "text",
        key_algorithm: Option<i32> = "int4",
        partition_count: Option<i32> = "int4",
        sub_method: Option<String> = "text",
        sub_expression: Option<String> = "text",
        sub_key_algorithm: Option<i32> = "int4",
        subpartition_count: Option<i32> = "int4",
    }
    Partitions = "engine_mysql.partitions" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        partitioning: Uuid = "uuid",
        parent: Option<Uuid> = "uuid",
        position: i32 = "int4",
        name: String = "text",
        values: Option<String> = "text",
        engine: Option<String> = "text",
        comment: Option<String> = "text",
        data_directory: Option<String> = "text",
        index_directory: Option<String> = "text",
        max_rows: Option<i64> = "int8",
        min_rows: Option<i64> = "int8",
        tablespace: Option<String> = "text",
    }
    Views = "engine_mysql.views" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        definition: String = "text",
        algorithm: String = "text",
        definer: String = "text",
        security: String = "text",
        check_option: Option<String> = "text",
        character_set_client: String = "text",
        collation_connection: String = "text",
    }
    Routines = "engine_mysql.routines" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        parameter_list: String = "text",
        returns: Option<String> = "text",
        deterministic: bool = "bool",
        data_access: String = "text",
        security: String = "text",
        definer: String = "text",
        language: String = "text",
        body: String = "text",
        sql_mode: String = "text",
        character_set_client: String = "text",
        collation_connection: String = "text",
        database_collation: String = "text",
    }
    RoutineParameters = "engine_mysql.routine_parameters" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        routine: Uuid = "uuid",
        position: i32 = "int4",
        mode: Option<String> = "text",
        name: String = "text",
        r#type: String = "text",
    }
    Triggers = "engine_mysql.triggers" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        timing: String = "text",
        event: String = "text",
        action_order: i32 = "int4",
        body: String = "text",
        definer: String = "text",
        sql_mode: String = "text",
        character_set_client: String = "text",
        collation_connection: String = "text",
        database_collation: String = "text",
    }
    Events = "engine_mysql.events" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        execute_at: Option<String> = "text",
        interval_value: Option<String> = "text",
        interval_field: Option<String> = "text",
        starts: Option<String> = "text",
        ends: Option<String> = "text",
        on_completion: String = "text",
        status: String = "text",
        body: String = "text",
        definer: String = "text",
        time_zone: String = "text",
        sql_mode: String = "text",
        character_set_client: String = "text",
        collation_connection: String = "text",
        database_collation: String = "text",
    }
    Libraries = "engine_mysql.libraries" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        language: String = "text",
        source: String = "text",
        sql_mode: String = "text",
    }
    Accounts = "engine_mysql.accounts" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        user_name: String = "text",
        host: String = "text",
        auth_plugin: Option<String> = "text",
        auth_string: Option<String> = "text",
        ssl_type: Option<String> = "text",
        ssl_cipher: Option<String> = "text",
        x509_issuer: Option<String> = "text",
        x509_subject: Option<String> = "text",
        max_queries_per_hour: i32 = "int4",
        max_updates_per_hour: i32 = "int4",
        max_connections_per_hour: i32 = "int4",
        max_user_connections: i32 = "int4",
        password_expire: Option<String> = "text",
        password_history: Option<String> = "text",
        password_reuse_interval: Option<String> = "text",
        password_require_current: Option<String> = "text",
        failed_login_attempts: Option<i32> = "int4",
        password_lock_time: Option<String> = "text",
        locked: bool = "bool",
        attributes: Option<String> = "text" => "jsonb",
    }
    RoleGrants = "engine_mysql.role_grants" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        grantee: Uuid = "uuid",
        role: Uuid = "uuid",
        admin_option: bool = "bool",
        is_default: bool = "bool",
    }
    Privileges = "engine_mysql.privileges" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        grantee: Uuid = "uuid",
        privilege: String = "text",
        level: String = "text",
        database_name: Option<String> = "text",
        object: Option<Uuid> = "uuid",
        object_name: Option<String> = "text",
        routine_kind: Option<String> = "text",
        column_name: Option<String> = "text",
        proxied: Option<Uuid> = "uuid",
        grant_option: bool = "bool",
    }
    Servers = "engine_mysql.servers" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        wrapper: String = "text",
        host: Option<String> = "text",
        port: Option<i32> = "int4",
        socket: Option<String> = "text",
        database_name: Option<String> = "text",
        user_name: Option<String> = "text",
        owner: Option<String> = "text",
    }
    LoadableFunctions = "engine_mysql.loadable_functions" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        returns: String = "text",
        aggregate: bool = "bool",
        library: String = "text",
    }
    Components = "engine_mysql.components" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        urn: String = "text",
    }
    ResourceGroups = "engine_mysql.resource_groups" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        r#type: String = "text",
        enabled: bool = "bool",
        vcpus: Option<String> = "text",
        thread_priority: i32 = "int4",
    }
    SpatialReferenceSystems = "engine_mysql.spatial_reference_systems" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        srs_id: i64 = "int8",
        definition: String = "text",
        organization: Option<String> = "text",
        organization_coordsys_id: Option<i64> = "int8",
        description: Option<String> = "text",
    }
    Tablespaces = "engine_mysql.tablespaces" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        engine: String = "text",
        file_name: String = "text",
        encryption: Option<bool> = "bool",
        autoextend_size: Option<String> = "text",
    }
    CompressionDictionaries = "engine_mysql.compression_dictionaries" {
        id: Uuid = "uuid",
        design: Uuid = "uuid",
        data: String = "text",
    }
}

/// Every destination table's rows: what an import stores, in the order it stores them (parents before children).
#[derive(Clone, Debug, Default)]
pub struct Rows {
    /// `cortex.namespaces`.
    pub namespaces: Namespaces,
    /// `cortex.objects`.
    pub objects: Objects,
    /// `cortex.columns`.
    pub columns: Columns,
    /// `cortex.indexes`.
    pub indexes: Indexes,
    /// `cortex.index_parts`.
    pub index_parts: IndexParts,
    /// `cortex.constraints`.
    pub constraints: Constraints,
    /// `cortex.constraint_columns`.
    pub constraint_columns: ConstraintColumns,
    /// `cortex.dependencies`.
    pub dependencies: Dependencies,
    /// `engine_mysql.instances`.
    pub instances: Instances,
    /// `engine_mysql.databases`.
    pub databases: Databases,
    /// `engine_mysql.tables`.
    pub tables: TableOptions,
    /// `engine_mysql.columns`.
    pub column_options: ColumnOptions,
    /// `engine_mysql.indexes`.
    pub index_options: IndexOptions,
    /// `engine_mysql.index_parts`.
    pub index_part_options: IndexPartOptions,
    /// `engine_mysql.partitionings`.
    pub partitionings: Partitionings,
    /// `engine_mysql.partitions`.
    pub partitions: Partitions,
    /// `engine_mysql.views`.
    pub views: Views,
    /// `engine_mysql.routines`.
    pub routines: Routines,
    /// `engine_mysql.routine_parameters`.
    pub routine_parameters: RoutineParameters,
    /// `engine_mysql.triggers`.
    pub triggers: Triggers,
    /// `engine_mysql.events`.
    pub events: Events,
    /// `engine_mysql.libraries`.
    pub libraries: Libraries,
    /// `engine_mysql.accounts`.
    pub accounts: Accounts,
    /// `engine_mysql.role_grants`.
    pub role_grants: RoleGrants,
    /// `engine_mysql.privileges`.
    pub privileges: Privileges,
    /// `engine_mysql.servers`.
    pub servers: Servers,
    /// `engine_mysql.loadable_functions`.
    pub loadable_functions: LoadableFunctions,
    /// `engine_mysql.components`.
    pub components: Components,
    /// `engine_mysql.resource_groups`.
    pub resource_groups: ResourceGroups,
    /// `engine_mysql.spatial_reference_systems`.
    pub spatial_reference_systems: SpatialReferenceSystems,
    /// `engine_mysql.tablespaces`.
    pub tablespaces: Tablespaces,
    /// `engine_mysql.compression_dictionaries`.
    pub compression_dictionaries: CompressionDictionaries,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_statement_stores_a_table_with_every_column_unnested() {
        let sql = Namespaces::insert_sql();
        assert_eq!(
            sql,
            "INSERT INTO cortex.namespaces (\"id\", \"design\", \"parent\", \"name\", \"position\", \"comment\") \
             SELECT u.\"id\", u.\"design\", u.\"parent\", u.\"name\", u.\"position\"::numeric, u.\"comment\" \
             FROM unnest($1::uuid[], $2::uuid[], $3::uuid[], $4::text[], $5::int4[], $6::text[]) \
             AS u(\"id\", \"design\", \"parent\", \"name\", \"position\", \"comment\")"
        );
        assert_eq!(Namespaces::default().params().len(), 6);
        assert!(Namespaces::default().is_empty());
    }

    #[test]
    fn one_query_loads_a_designs_rows_of_a_table_with_casts_undone() {
        assert_eq!(
            Namespaces::select_sql(),
            "SELECT \"id\", \"design\", \"parent\", \"name\", \"position\"::int4 AS \"position\", \"comment\" \
             FROM cortex.namespaces WHERE design = $1 ORDER BY id"
        );
        assert!(Accounts::select_sql().contains("\"attributes\"::text AS \"attributes\""));
        assert!(Dependencies::select_sql().contains("\"as\""));
    }

    #[test]
    fn a_jsonb_column_is_bound_as_text_and_cast_in_the_select_list() {
        let sql = Accounts::insert_sql();
        assert!(sql.contains("u.\"attributes\"::jsonb"));
        assert!(sql.contains("::text[]) AS u("));
        assert!(Dependencies::insert_sql().contains("\"as\""));
    }
}
