//! What a MySQL server holds, as MySQL lists it: one typed struct per catalog source, its fields the source's columns
//! by their MySQL names in snake case, each read with its own query as typed rows. Which sources and columns a server
//! has is decided once, from a probe of `information_schema.COLUMNS`, never by trying a query and seeing it fail. Every
//! query leaves out the system databases (`mysql`, `information_schema`, `performance_schema`, `sys`) and the server's
//! own accounts and components.

use std::collections::BTreeSet;
use std::fmt::Display;

use mysql_async::prelude::Queryable;
use mysql_async::{Pool, Row};
use schema_forge_engine::EngineError;

/// The system databases, as a SQL list.
const SYSTEM: &str = "('mysql', 'information_schema', 'performance_schema', 'sys')";

/// A catalog error as an engine's: the source server's.
pub(crate) fn source_error(e: impl Display) -> EngineError {
    EngineError::Source(e.to_string())
}

/// Whether an account is the server's own, never a design's: `root`, MySQL's (`mysql.sys`, `mysql.session`,
/// `mysql.infoschema`) and Percona Server's (`percona.telemetry`).
pub(crate) fn is_system_account(user: &str) -> bool {
    user == "root" || user.starts_with("mysql.") || user.starts_with("percona.")
}

/// Percona Server's telemetry component, installed by the server itself.
const SYSTEM_COMPONENT: &str = "file://component_percona_telemetry";

// --- what the server has -------------------------------------------------------------------------------------------------

/// Which catalog tables and columns a server has, probed once.
#[derive(Clone, Debug, Default)]
pub struct Capabilities {
    columns: BTreeSet<(String, String, String)>,
}

impl Capabilities {
    /// Probes `information_schema.COLUMNS` for the catalog tables of `information_schema` and `mysql`.
    pub async fn probe(pool: &Pool) -> Result<Capabilities, EngineError> {
        let mut conn = pool.get_conn().await.map_err(source_error)?;
        let rows: Vec<(String, String, String)> = conn
            .query(
                "SELECT LOWER(TABLE_SCHEMA), LOWER(TABLE_NAME), LOWER(COLUMN_NAME) FROM information_schema.COLUMNS \
                 WHERE TABLE_SCHEMA IN ('information_schema', 'mysql')",
            )
            .await
            .map_err(source_error)?;
        Ok(Capabilities {
            columns: rows.into_iter().collect(),
        })
    }

    /// Capabilities from (schema, table, column) triples, for a test.
    #[must_use]
    pub fn of(columns: &[(&str, &str, &str)]) -> Capabilities {
        Capabilities {
            columns: columns
                .iter()
                .map(|(s, t, c)| (s.to_lowercase(), t.to_lowercase(), c.to_lowercase()))
                .collect(),
        }
    }

    /// Whether the server has a catalog table.
    #[must_use]
    pub fn table(&self, schema: &str, table: &str) -> bool {
        let (schema, table) = (schema.to_lowercase(), table.to_lowercase());
        self.columns.iter().any(|(s, t, _)| *s == schema && *t == table)
    }

    /// Whether a catalog table has a column.
    #[must_use]
    pub fn column(&self, schema: &str, table: &str, column: &str) -> bool {
        self.columns
            .contains(&(schema.to_lowercase(), table.to_lowercase(), column.to_lowercase()))
    }
}

// --- reading a row ---------------------------------------------------------------------------------------------------------

/// A row whose cells are taken by name, typed.
struct Cells {
    row: Row,
    source: &'static str,
}

impl Cells {
    fn new(row: Row, source: &'static str) -> Cells {
        Cells { row, source }
    }

    fn take<T: mysql_async::prelude::FromValue>(&mut self, name: &str) -> Result<T, EngineError> {
        match self.row.take_opt::<T, _>(name) {
            Some(Ok(value)) => Ok(value),
            Some(Err(e)) => Err(EngineError::Source(format!("{}: the column {name}: {e}", self.source))),
            None => Err(EngineError::Source(format!(
                "{}: the column {name} is missing",
                self.source
            ))),
        }
    }

    fn text(&mut self, name: &str) -> Result<String, EngineError> {
        Ok(self.take::<Option<String>>(name)?.unwrap_or_default())
    }

    fn opt(&mut self, name: &str) -> Result<Option<String>, EngineError> {
        self.take(name)
    }

    fn int(&mut self, name: &str) -> Result<i64, EngineError> {
        Ok(self.take::<Option<i64>>(name)?.unwrap_or_default())
    }

    fn opt_int(&mut self, name: &str) -> Result<Option<i64>, EngineError> {
        self.take(name)
    }

    fn flag(&mut self, name: &str) -> Result<bool, EngineError> {
        Ok(self.int(name)? != 0)
    }
}

/// Runs one query and decodes each row.
async fn fetch<T>(
    pool: &Pool,
    source: &'static str,
    sql: &str,
    decode: impl Fn(Cells) -> Result<T, EngineError>,
) -> Result<Vec<T>, EngineError> {
    let mut conn = pool.get_conn().await.map_err(source_error)?;
    let rows: Vec<Row> = conn
        .query(sql)
        .await
        .map_err(|e| EngineError::Source(format!("{source}: {e}")))?;
    rows.into_iter().map(|row| decode(Cells::new(row, source))).collect()
}

// --- the sources -------------------------------------------------------------------------------------------------------------
// Fields hold the source's columns as it lists them; every field is documented by its source's name.

/// `information_schema.SCHEMATA`: a database.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Schemata {
    /// `SCHEMA_NAME`.
    pub schema_name: String,
    /// `DEFAULT_CHARACTER_SET_NAME`.
    pub default_character_set_name: String,
    /// `DEFAULT_COLLATION_NAME`.
    pub default_collation_name: String,
    /// `DEFAULT_ENCRYPTION` (8.0.16 and later): `YES` or `NO`.
    pub default_encryption: Option<String>,
}

/// `information_schema.SCHEMATA_EXTENSIONS` (8.0.22 and later): a database's options.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SchemataExtension {
    /// `SCHEMA_NAME`.
    pub schema_name: String,
    /// `OPTIONS`: `READ ONLY=1` where read only.
    pub options: Option<String>,
}

/// `information_schema.TABLES`, base tables.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TableRow {
    /// `TABLE_SCHEMA`.
    pub table_schema: String,
    /// `TABLE_NAME`.
    pub table_name: String,
    /// `ENGINE`.
    pub engine: Option<String>,
    /// `TABLE_COLLATION`.
    pub table_collation: Option<String>,
    /// `CREATE_OPTIONS`: the options the table was made with, as `key=value` words.
    pub create_options: Option<String>,
    /// `TABLE_COMMENT`.
    pub table_comment: String,
}

/// `information_schema.COLUMNS`: a column of a table or a view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ColumnRow {
    /// `TABLE_SCHEMA`.
    pub table_schema: String,
    /// `TABLE_NAME`.
    pub table_name: String,
    /// `ORDINAL_POSITION`.
    pub ordinal_position: i64,
    /// `COLUMN_NAME`.
    pub column_name: String,
    /// `COLUMN_TYPE`.
    pub column_type: String,
    /// `IS_NULLABLE = 'YES'`.
    pub is_nullable: bool,
    /// `COLUMN_DEFAULT`.
    pub column_default: Option<String>,
    /// `EXTRA`.
    pub extra: String,
    /// `GENERATION_EXPRESSION`.
    pub generation_expression: Option<String>,
    /// `CHARACTER_SET_NAME`.
    pub character_set_name: Option<String>,
    /// `COLLATION_NAME`.
    pub collation_name: Option<String>,
    /// `COLUMN_COMMENT`.
    pub column_comment: String,
    /// `SRS_ID` (8.0 and later).
    pub srs_id: Option<i64>,
}

/// `information_schema.STATISTICS`: one part of an index.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Statistic {
    /// `TABLE_SCHEMA`.
    pub table_schema: String,
    /// `TABLE_NAME`.
    pub table_name: String,
    /// `INDEX_NAME`.
    pub index_name: String,
    /// `NON_UNIQUE`, as a flag.
    pub non_unique: bool,
    /// `SEQ_IN_INDEX`.
    pub seq_in_index: i64,
    /// `COLUMN_NAME`; NULL for an expression.
    pub column_name: Option<String>,
    /// `SUB_PART`: the prefix length.
    pub sub_part: Option<i64>,
    /// `COLLATION`: `A` ascending, `D` descending.
    pub collation: Option<String>,
    /// `INDEX_TYPE`.
    pub index_type: String,
    /// `INDEX_COMMENT`.
    pub index_comment: String,
    /// `EXPRESSION` (8.0.13 and later).
    pub expression: Option<String>,
    /// `IS_VISIBLE` (8.0 and later): `YES` or `NO`.
    pub is_visible: Option<String>,
}

/// `information_schema.KEY_COLUMN_USAGE` joined to `REFERENTIAL_CONSTRAINTS`: one column of a foreign key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ForeignKeyColumn {
    /// `TABLE_SCHEMA`.
    pub table_schema: String,
    /// `TABLE_NAME`.
    pub table_name: String,
    /// `CONSTRAINT_NAME`.
    pub constraint_name: String,
    /// `COLUMN_NAME`.
    pub column_name: String,
    /// `ORDINAL_POSITION`.
    pub ordinal_position: i64,
    /// `UNIQUE_CONSTRAINT_SCHEMA`: the referenced table's database.
    pub referenced_table_schema: String,
    /// `REFERENCED_TABLE_NAME`.
    pub referenced_table_name: String,
    /// `REFERENCED_COLUMN_NAME`.
    pub referenced_column_name: String,
    /// `UPDATE_RULE`.
    pub update_rule: String,
    /// `DELETE_RULE`.
    pub delete_rule: String,
}

/// `information_schema.CHECK_CONSTRAINTS` joined to `TABLE_CONSTRAINTS` (8.0.16 and later): a check.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CheckConstraint {
    /// `TABLE_SCHEMA`.
    pub table_schema: String,
    /// `TABLE_NAME`.
    pub table_name: String,
    /// `CONSTRAINT_NAME`.
    pub constraint_name: String,
    /// `CHECK_CLAUSE`.
    pub check_clause: String,
    /// `ENFORCED = 'YES'`.
    pub enforced: bool,
}

/// `information_schema.PARTITIONS`: a partition or a subpartition.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PartitionRow {
    /// `TABLE_SCHEMA`.
    pub table_schema: String,
    /// `TABLE_NAME`.
    pub table_name: String,
    /// `PARTITION_NAME`.
    pub partition_name: String,
    /// `SUBPARTITION_NAME`.
    pub subpartition_name: Option<String>,
    /// `PARTITION_ORDINAL_POSITION`.
    pub partition_ordinal_position: i64,
    /// `SUBPARTITION_ORDINAL_POSITION`.
    pub subpartition_ordinal_position: Option<i64>,
    /// `PARTITION_METHOD`.
    pub partition_method: String,
    /// `SUBPARTITION_METHOD`.
    pub subpartition_method: Option<String>,
    /// `PARTITION_EXPRESSION`.
    pub partition_expression: Option<String>,
    /// `SUBPARTITION_EXPRESSION`.
    pub subpartition_expression: Option<String>,
    /// `PARTITION_DESCRIPTION`.
    pub partition_description: Option<String>,
    /// `PARTITION_COMMENT`.
    pub partition_comment: String,
}

/// `information_schema.VIEWS`: a view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ViewRow {
    /// `TABLE_SCHEMA`.
    pub table_schema: String,
    /// `TABLE_NAME`.
    pub table_name: String,
    /// `CHECK_OPTION`: `NONE`, `LOCAL` or `CASCADED`.
    pub check_option: String,
    /// `DEFINER`.
    pub definer: String,
    /// `SECURITY_TYPE`.
    pub security_type: String,
    /// `CHARACTER_SET_CLIENT`.
    pub character_set_client: String,
    /// `COLLATION_CONNECTION`.
    pub collation_connection: String,
}

/// `information_schema.VIEW_TABLE_USAGE` (8.0.13 and later): a table or view a view reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ViewTable {
    /// `VIEW_SCHEMA`.
    pub view_schema: String,
    /// `VIEW_NAME`.
    pub view_name: String,
    /// `TABLE_SCHEMA`.
    pub table_schema: String,
    /// `TABLE_NAME`.
    pub table_name: String,
}

/// `information_schema.ROUTINES`: a procedure or function.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoutineRow {
    /// `ROUTINE_SCHEMA`.
    pub routine_schema: String,
    /// `ROUTINE_NAME`.
    pub routine_name: String,
    /// `ROUTINE_TYPE`: `PROCEDURE` or `FUNCTION`.
    pub routine_type: String,
    /// `IS_DETERMINISTIC = 'YES'`.
    pub is_deterministic: bool,
    /// `SQL_DATA_ACCESS`.
    pub sql_data_access: String,
    /// `SECURITY_TYPE`.
    pub security_type: String,
    /// `DEFINER`.
    pub definer: String,
    /// `SQL_MODE`.
    pub sql_mode: String,
    /// `ROUTINE_COMMENT`.
    pub routine_comment: String,
    /// `CHARACTER_SET_CLIENT`.
    pub character_set_client: String,
    /// `COLLATION_CONNECTION`.
    pub collation_connection: String,
    /// `DATABASE_COLLATION`.
    pub database_collation: String,
    /// `EXTERNAL_LANGUAGE` (9.x), where the column exists.
    pub external_language: Option<String>,
}

/// `information_schema.PARAMETERS`: a parameter of a routine, or (position 0) a function's return.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParameterRow {
    /// `SPECIFIC_SCHEMA`.
    pub specific_schema: String,
    /// `SPECIFIC_NAME`.
    pub specific_name: String,
    /// `ROUTINE_TYPE`.
    pub routine_type: String,
    /// `ORDINAL_POSITION`.
    pub ordinal_position: i64,
    /// `PARAMETER_MODE`.
    pub parameter_mode: Option<String>,
    /// `PARAMETER_NAME`.
    pub parameter_name: Option<String>,
    /// `DTD_IDENTIFIER`.
    pub dtd_identifier: String,
}

/// `information_schema.TRIGGERS`: a trigger.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TriggerRow {
    /// `TRIGGER_SCHEMA`.
    pub trigger_schema: String,
    /// `TRIGGER_NAME`.
    pub trigger_name: String,
    /// `EVENT_OBJECT_TABLE`.
    pub event_object_table: String,
    /// `ACTION_TIMING`.
    pub action_timing: String,
    /// `EVENT_MANIPULATION`.
    pub event_manipulation: String,
    /// `ACTION_ORDER`.
    pub action_order: i64,
    /// `ACTION_STATEMENT`.
    pub action_statement: String,
    /// `DEFINER`.
    pub definer: String,
    /// `SQL_MODE`.
    pub sql_mode: String,
    /// `CHARACTER_SET_CLIENT`.
    pub character_set_client: String,
    /// `COLLATION_CONNECTION`.
    pub collation_connection: String,
    /// `DATABASE_COLLATION`.
    pub database_collation: String,
}

/// `information_schema.EVENTS`: a scheduled event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EventRow {
    /// `EVENT_SCHEMA`.
    pub event_schema: String,
    /// `EVENT_NAME`.
    pub event_name: String,
    /// `EVENT_DEFINITION`.
    pub event_definition: String,
    /// `EXECUTE_AT`, as the server writes it.
    pub execute_at: Option<String>,
    /// `INTERVAL_VALUE`, as the server writes it.
    pub interval_value: Option<String>,
    /// `INTERVAL_FIELD`.
    pub interval_field: Option<String>,
    /// `STARTS`, as the server writes it.
    pub starts: Option<String>,
    /// `ENDS`, as the server writes it.
    pub ends: Option<String>,
    /// `STATUS`.
    pub status: String,
    /// `ON_COMPLETION`.
    pub on_completion: String,
    /// `EVENT_COMMENT`.
    pub event_comment: String,
    /// `DEFINER`.
    pub definer: String,
    /// `TIME_ZONE`.
    pub time_zone: String,
    /// `SQL_MODE`.
    pub sql_mode: String,
    /// `CHARACTER_SET_CLIENT`.
    pub character_set_client: String,
    /// `COLLATION_CONNECTION`.
    pub collation_connection: String,
    /// `DATABASE_COLLATION`.
    pub database_collation: String,
}

/// `information_schema.LIBRARIES` (9.x): a JavaScript library.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LibraryRow {
    /// `LIBRARY_SCHEMA`.
    pub library_schema: String,
    /// `LIBRARY_NAME`.
    pub library_name: String,
    /// `LIBRARY_DEFINITION`.
    pub library_definition: String,
    /// `LANGUAGE`.
    pub language: String,
    /// `SQL_MODE`.
    pub sql_mode: String,
    /// `LIBRARY_COMMENT`.
    pub library_comment: Option<String>,
}

/// `information_schema.ROUTINE_LIBRARIES` (9.x): a library a routine uses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoutineLibrary {
    /// `ROUTINE_SCHEMA`.
    pub routine_schema: String,
    /// `ROUTINE_NAME`.
    pub routine_name: String,
    /// `ROUTINE_TYPE`.
    pub routine_type: String,
    /// `LIBRARY_SCHEMA`.
    pub library_schema: String,
    /// `LIBRARY_NAME`.
    pub library_name: String,
}

/// `information_schema.INNODB_TABLESPACES` (or `INNODB_SYS_TABLESPACES` on 5.7) joined to `FILES`: a general tablespace.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TablespaceRow {
    /// `NAME`.
    pub name: String,
    /// `FILES.FILE_NAME`.
    pub file_name: Option<String>,
    /// `ENCRYPTION`: `Y` or `N`, where the column exists.
    pub encryption: Option<String>,
    /// `AUTOEXTEND_SIZE` in bytes, where the column exists.
    pub autoextend_size: Option<i64>,
}

/// `information_schema.ST_SPATIAL_REFERENCE_SYSTEMS` (8.0): a spatial reference system made on the server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpatialReferenceSystemRow {
    /// `SRS_NAME`.
    pub srs_name: String,
    /// `SRS_ID`.
    pub srs_id: i64,
    /// `ORGANIZATION`.
    pub organization: Option<String>,
    /// `ORGANIZATION_COORDSYS_ID`.
    pub organization_coordsys_id: Option<i64>,
    /// `DEFINITION`.
    pub definition: String,
    /// `DESCRIPTION`.
    pub description: Option<String>,
}

/// `information_schema.RESOURCE_GROUPS` (8.0): a resource group made on the server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResourceGroupRow {
    /// `RESOURCE_GROUP_NAME`.
    pub resource_group_name: String,
    /// `RESOURCE_GROUP_TYPE`.
    pub resource_group_type: String,
    /// `RESOURCE_GROUP_ENABLED`.
    pub resource_group_enabled: bool,
    /// `VCPU_IDS`, as text.
    pub vcpu_ids: Option<String>,
    /// `THREAD_PRIORITY`.
    pub thread_priority: i64,
}

/// Percona's `information_schema.COMPRESSION_DICTIONARY` (8.0) or `XTRADB_ZIP_DICT` (5.7): a compression dictionary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompressionDictionaryRow {
    /// The dictionary's name.
    pub name: String,
    /// Its data, as text.
    pub data: String,
}

/// One privilege of `information_schema`'s `USER_PRIVILEGES`, `SCHEMA_PRIVILEGES`, `TABLE_PRIVILEGES` or
/// `COLUMN_PRIVILEGES`: what the columns the level does not have hold NULL.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GrantRow {
    /// `GRANTEE`, as `'user'@'host'`.
    pub grantee: String,
    /// `TABLE_SCHEMA`, from the database level down.
    pub table_schema: Option<String>,
    /// `TABLE_NAME`, from the table level down.
    pub table_name: Option<String>,
    /// `COLUMN_NAME`, at the column level.
    pub column_name: Option<String>,
    /// `PRIVILEGE_TYPE`.
    pub privilege_type: String,
    /// `IS_GRANTABLE = 'YES'`.
    pub is_grantable: bool,
}

/// `mysql.procs_priv`: privileges on a routine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoutinePrivilege {
    /// `User`.
    pub user: String,
    /// `Host`.
    pub host: String,
    /// `Db`.
    pub db: String,
    /// `Routine_name`.
    pub routine_name: String,
    /// `Routine_type`: `PROCEDURE` or `FUNCTION`.
    pub routine_type: String,
    /// `Proc_priv`: a set of `Execute`, `Alter Routine`, `Grant`.
    pub proc_priv: String,
}

/// `mysql.proxies_priv`: an account that may act as another.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProxyPrivilege {
    /// `User`.
    pub user: String,
    /// `Host`.
    pub host: String,
    /// `Proxied_user`.
    pub proxied_user: String,
    /// `Proxied_host`.
    pub proxied_host: String,
    /// `With_grant`.
    pub with_grant: bool,
}

/// `mysql.user`: an account or a role.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AccountRow {
    /// `User`.
    pub user: String,
    /// `Host`.
    pub host: String,
}

/// `mysql.role_edges` (8.0): a role granted to an account or role.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoleEdge {
    /// `FROM_USER`: the role.
    pub from_user: String,
    /// `FROM_HOST`.
    pub from_host: String,
    /// `TO_USER`: the grantee.
    pub to_user: String,
    /// `TO_HOST`.
    pub to_host: String,
    /// `WITH_ADMIN_OPTION = 'Y'`.
    pub with_admin_option: bool,
}

/// `mysql.default_roles` (8.0): a default role of an account.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DefaultRole {
    /// `USER`.
    pub user: String,
    /// `HOST`.
    pub host: String,
    /// `DEFAULT_ROLE_USER`.
    pub default_role_user: String,
    /// `DEFAULT_ROLE_HOST`.
    pub default_role_host: String,
}

/// `mysql.servers`: a server a FEDERATED table connects through.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerRow {
    /// `Server_name`.
    pub server_name: String,
    /// `Host`.
    pub host: String,
    /// `Db`.
    pub db: String,
    /// `Username`.
    pub username: String,
    /// `Port`.
    pub port: i64,
    /// `Socket`.
    pub socket: String,
    /// `Wrapper`.
    pub wrapper: String,
    /// `Owner`.
    pub owner: String,
}

/// `mysql.func`: a loadable function.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LoadableFunctionRow {
    /// `name`.
    pub name: String,
    /// `ret`: 0 string, 1 real, 2 integer, 4 decimal.
    pub ret: i64,
    /// `dl`: the library file.
    pub dl: String,
    /// `type`: `function` or `aggregate`.
    pub kind: String,
}

/// Everything a server's catalogs hold that a design takes.
#[derive(Clone, Debug, Default)]
pub struct Catalog {
    /// `SCHEMATA`.
    pub schemata: Vec<Schemata>,
    /// `SCHEMATA_EXTENSIONS`.
    pub schemata_extensions: Vec<SchemataExtension>,
    /// `TABLES`.
    pub tables: Vec<TableRow>,
    /// `COLUMNS`.
    pub columns: Vec<ColumnRow>,
    /// `STATISTICS`.
    pub statistics: Vec<Statistic>,
    /// Foreign keys.
    pub foreign_keys: Vec<ForeignKeyColumn>,
    /// Check constraints.
    pub checks: Vec<CheckConstraint>,
    /// `PARTITIONS`.
    pub partitions: Vec<PartitionRow>,
    /// `VIEWS`.
    pub views: Vec<ViewRow>,
    /// `VIEW_TABLE_USAGE`.
    pub view_tables: Vec<ViewTable>,
    /// `ROUTINES`.
    pub routines: Vec<RoutineRow>,
    /// `PARAMETERS`.
    pub parameters: Vec<ParameterRow>,
    /// `TRIGGERS`.
    pub triggers: Vec<TriggerRow>,
    /// `EVENTS`.
    pub events: Vec<EventRow>,
    /// `LIBRARIES`.
    pub libraries: Vec<LibraryRow>,
    /// `ROUTINE_LIBRARIES`.
    pub routine_libraries: Vec<RoutineLibrary>,
    /// General tablespaces.
    pub tablespaces: Vec<TablespaceRow>,
    /// User-made spatial reference systems.
    pub spatial_reference_systems: Vec<SpatialReferenceSystemRow>,
    /// User-made resource groups.
    pub resource_groups: Vec<ResourceGroupRow>,
    /// Compression dictionaries.
    pub compression_dictionaries: Vec<CompressionDictionaryRow>,
    /// Privileges at the server level.
    pub user_privileges: Vec<GrantRow>,
    /// Privileges at the database level.
    pub schema_privileges: Vec<GrantRow>,
    /// Privileges at the table level.
    pub table_privileges: Vec<GrantRow>,
    /// Privileges at the column level.
    pub column_privileges: Vec<GrantRow>,
    /// Privileges on routines.
    pub routine_privileges: Vec<RoutinePrivilege>,
    /// Proxy privileges.
    pub proxy_privileges: Vec<ProxyPrivilege>,
    /// Accounts and roles, the server's own left out.
    pub accounts: Vec<AccountRow>,
    /// Roles granted.
    pub role_edges: Vec<RoleEdge>,
    /// Default roles.
    pub default_roles: Vec<DefaultRole>,
    /// FEDERATED servers.
    pub servers: Vec<ServerRow>,
    /// Loadable functions.
    pub loadable_functions: Vec<LoadableFunctionRow>,
    /// Installed components' URNs, the server's own left out.
    pub components: Vec<String>,
}

// --- the queries -----------------------------------------------------------------------------------------------------------

/// Runs `query` when the server has `table`, and gives nothing otherwise.
async fn when<T>(
    has: bool,
    query: impl std::future::Future<Output = Result<Vec<T>, EngineError>>,
) -> Result<Vec<T>, EngineError> {
    if has { query.await } else { Ok(Vec::new()) }
}

impl Catalog {
    /// Asks every source the server has, all at once, each one query; the pool bounds how many run together.
    pub async fn read(pool: &Pool, caps: &Capabilities) -> Result<Catalog, EngineError> {
        let ischema = |t: &str| caps.table("information_schema", t);
        let mysql = |t: &str| caps.table("mysql", t);
        let (
            schemata,
            schemata_extensions,
            tables,
            columns,
            statistics,
            foreign_keys,
            checks,
            partitions,
            views,
            view_tables,
            routines,
            parameters,
            triggers,
            events,
            libraries,
            routine_libraries,
            tablespaces,
            spatial_reference_systems,
            resource_groups,
            compression_dictionaries,
        ) = futures_util::try_join!(
            fetch_schemata(pool, caps),
            when(ischema("schemata_extensions"), fetch_schemata_extensions(pool)),
            fetch_tables(pool),
            fetch_columns(pool, caps),
            fetch_statistics(pool, caps),
            fetch_foreign_keys(pool),
            when(ischema("check_constraints"), fetch_checks(pool)),
            fetch_partitions(pool),
            fetch_views(pool),
            when(ischema("view_table_usage"), fetch_view_tables(pool)),
            fetch_routines(pool, caps),
            fetch_parameters(pool),
            fetch_triggers(pool),
            fetch_events(pool),
            when(ischema("libraries"), fetch_libraries(pool)),
            when(ischema("routine_libraries"), fetch_routine_libraries(pool)),
            fetch_tablespaces(pool, caps),
            when(
                ischema("st_spatial_reference_systems"),
                fetch_spatial_reference_systems(pool)
            ),
            when(ischema("resource_groups"), fetch_resource_groups(pool)),
            fetch_compression_dictionaries(pool, caps),
        )?;
        let (
            user_privileges,
            schema_privileges,
            table_privileges,
            column_privileges,
            routine_privileges,
            proxy_privileges,
            accounts,
            role_edges,
            default_roles,
            servers,
            loadable_functions,
            components,
        ) = futures_util::try_join!(
            fetch_grants(pool, "user_privileges", "NULL", "NULL", "NULL"),
            fetch_grants(pool, "schema_privileges", "TABLE_SCHEMA", "NULL", "NULL"),
            fetch_grants(pool, "table_privileges", "TABLE_SCHEMA", "TABLE_NAME", "NULL"),
            fetch_grants(pool, "column_privileges", "TABLE_SCHEMA", "TABLE_NAME", "COLUMN_NAME"),
            when(mysql("procs_priv"), fetch_routine_privileges(pool)),
            when(mysql("proxies_priv"), fetch_proxy_privileges(pool)),
            fetch_accounts(pool),
            when(mysql("role_edges"), fetch_role_edges(pool)),
            when(mysql("default_roles"), fetch_default_roles(pool)),
            when(mysql("servers"), fetch_servers(pool)),
            when(mysql("func"), fetch_loadable_functions(pool)),
            when(mysql("component"), fetch_components(pool)),
        )?;
        Ok(Catalog {
            schemata,
            schemata_extensions,
            tables,
            columns,
            statistics,
            foreign_keys,
            checks,
            partitions,
            views,
            view_tables,
            routines,
            parameters,
            triggers,
            events,
            libraries,
            routine_libraries,
            tablespaces,
            spatial_reference_systems,
            resource_groups,
            compression_dictionaries,
            user_privileges,
            schema_privileges,
            table_privileges,
            column_privileges,
            routine_privileges,
            proxy_privileges,
            accounts,
            role_edges,
            default_roles,
            servers,
            loadable_functions,
            components,
        })
    }
}

/// A column of a catalog table, or `NULL` where the server's version lacks it.
fn col(caps: &Capabilities, table: &str, column: &str) -> String {
    if caps.column("information_schema", table, column) {
        column.to_string()
    } else {
        "NULL".to_string()
    }
}

async fn fetch_schemata(pool: &Pool, caps: &Capabilities) -> Result<Vec<Schemata>, EngineError> {
    let sql = format!(
        "SELECT SCHEMA_NAME AS schema_name, DEFAULT_CHARACTER_SET_NAME AS default_character_set_name, \
         DEFAULT_COLLATION_NAME AS default_collation_name, {} AS default_encryption \
         FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN {SYSTEM} ORDER BY SCHEMA_NAME",
        col(caps, "schemata", "DEFAULT_ENCRYPTION")
    );
    fetch(pool, "SCHEMATA", &sql, |mut c| {
        Ok(Schemata {
            schema_name: c.text("schema_name")?,
            default_character_set_name: c.text("default_character_set_name")?,
            default_collation_name: c.text("default_collation_name")?,
            default_encryption: c.opt("default_encryption")?,
        })
    })
    .await
}

async fn fetch_schemata_extensions(pool: &Pool) -> Result<Vec<SchemataExtension>, EngineError> {
    let sql = format!(
        "SELECT SCHEMA_NAME AS schema_name, OPTIONS AS options FROM information_schema.SCHEMATA_EXTENSIONS \
         WHERE SCHEMA_NAME NOT IN {SYSTEM}"
    );
    fetch(pool, "SCHEMATA_EXTENSIONS", &sql, |mut c| {
        Ok(SchemataExtension {
            schema_name: c.text("schema_name")?,
            options: c.opt("options")?,
        })
    })
    .await
}

async fn fetch_tables(pool: &Pool) -> Result<Vec<TableRow>, EngineError> {
    let sql = format!(
        "SELECT TABLE_SCHEMA AS table_schema, TABLE_NAME AS table_name, ENGINE AS engine, \
         TABLE_COLLATION AS table_collation, CREATE_OPTIONS AS create_options, TABLE_COMMENT AS table_comment \
         FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN {SYSTEM} AND TABLE_TYPE = 'BASE TABLE' \
         ORDER BY TABLE_SCHEMA, TABLE_NAME"
    );
    fetch(pool, "TABLES", &sql, |mut c| {
        Ok(TableRow {
            table_schema: c.text("table_schema")?,
            table_name: c.text("table_name")?,
            engine: c.opt("engine")?,
            table_collation: c.opt("table_collation")?,
            create_options: c.opt("create_options")?,
            table_comment: c.text("table_comment")?,
        })
    })
    .await
}

async fn fetch_columns(pool: &Pool, caps: &Capabilities) -> Result<Vec<ColumnRow>, EngineError> {
    let sql = format!(
        "SELECT TABLE_SCHEMA AS table_schema, TABLE_NAME AS table_name, ORDINAL_POSITION AS ordinal_position, \
         COLUMN_NAME AS column_name, CAST(COLUMN_TYPE AS CHAR) AS column_type, (IS_NULLABLE = 'YES') AS is_nullable, \
         COLUMN_DEFAULT AS column_default, EXTRA AS extra, GENERATION_EXPRESSION AS generation_expression, \
         CHARACTER_SET_NAME AS character_set_name, COLLATION_NAME AS collation_name, COLUMN_COMMENT AS column_comment, \
         {} AS srs_id FROM information_schema.COLUMNS WHERE TABLE_SCHEMA NOT IN {SYSTEM} \
         ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION",
        col(caps, "columns", "SRS_ID")
    );
    fetch(pool, "COLUMNS", &sql, |mut c| {
        Ok(ColumnRow {
            table_schema: c.text("table_schema")?,
            table_name: c.text("table_name")?,
            ordinal_position: c.int("ordinal_position")?,
            column_name: c.text("column_name")?,
            column_type: c.text("column_type")?,
            is_nullable: c.flag("is_nullable")?,
            column_default: c.opt("column_default")?,
            extra: c.text("extra")?,
            generation_expression: c.opt("generation_expression")?,
            character_set_name: c.opt("character_set_name")?,
            collation_name: c.opt("collation_name")?,
            column_comment: c.text("column_comment")?,
            srs_id: c.opt_int("srs_id")?,
        })
    })
    .await
}

async fn fetch_statistics(pool: &Pool, caps: &Capabilities) -> Result<Vec<Statistic>, EngineError> {
    let sql = format!(
        "SELECT TABLE_SCHEMA AS table_schema, TABLE_NAME AS table_name, INDEX_NAME AS index_name, \
         NON_UNIQUE AS non_unique, SEQ_IN_INDEX AS seq_in_index, COLUMN_NAME AS column_name, SUB_PART AS sub_part, \
         COLLATION AS collation, INDEX_TYPE AS index_type, INDEX_COMMENT AS index_comment, {} AS expression, \
         {} AS is_visible FROM information_schema.STATISTICS WHERE TABLE_SCHEMA NOT IN {SYSTEM} \
         ORDER BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX",
        col(caps, "statistics", "EXPRESSION"),
        col(caps, "statistics", "IS_VISIBLE")
    );
    fetch(pool, "STATISTICS", &sql, |mut c| {
        Ok(Statistic {
            table_schema: c.text("table_schema")?,
            table_name: c.text("table_name")?,
            index_name: c.text("index_name")?,
            non_unique: c.flag("non_unique")?,
            seq_in_index: c.int("seq_in_index")?,
            column_name: c.opt("column_name")?,
            sub_part: c.opt_int("sub_part")?,
            collation: c.opt("collation")?,
            index_type: c.text("index_type")?,
            index_comment: c.text("index_comment")?,
            expression: c.opt("expression")?,
            is_visible: c.opt("is_visible")?,
        })
    })
    .await
}

async fn fetch_foreign_keys(pool: &Pool) -> Result<Vec<ForeignKeyColumn>, EngineError> {
    let sql = format!(
        "SELECT k.TABLE_SCHEMA AS table_schema, k.TABLE_NAME AS table_name, k.CONSTRAINT_NAME AS constraint_name, \
         k.COLUMN_NAME AS column_name, k.ORDINAL_POSITION AS ordinal_position, \
         r.UNIQUE_CONSTRAINT_SCHEMA AS referenced_table_schema, k.REFERENCED_TABLE_NAME AS referenced_table_name, \
         k.REFERENCED_COLUMN_NAME AS referenced_column_name, r.UPDATE_RULE AS update_rule, r.DELETE_RULE AS delete_rule \
         FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r \
         ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME \
         AND r.TABLE_NAME = k.TABLE_NAME WHERE k.TABLE_SCHEMA NOT IN {SYSTEM} \
         ORDER BY k.TABLE_SCHEMA, k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION"
    );
    fetch(pool, "KEY_COLUMN_USAGE", &sql, |mut c| {
        Ok(ForeignKeyColumn {
            table_schema: c.text("table_schema")?,
            table_name: c.text("table_name")?,
            constraint_name: c.text("constraint_name")?,
            column_name: c.text("column_name")?,
            ordinal_position: c.int("ordinal_position")?,
            referenced_table_schema: c.text("referenced_table_schema")?,
            referenced_table_name: c.text("referenced_table_name")?,
            referenced_column_name: c.text("referenced_column_name")?,
            update_rule: c.text("update_rule")?,
            delete_rule: c.text("delete_rule")?,
        })
    })
    .await
}

async fn fetch_checks(pool: &Pool) -> Result<Vec<CheckConstraint>, EngineError> {
    let sql = format!(
        "SELECT t.TABLE_SCHEMA AS table_schema, t.TABLE_NAME AS table_name, t.CONSTRAINT_NAME AS constraint_name, \
         c.CHECK_CLAUSE AS check_clause, (t.ENFORCED = 'YES') AS enforced \
         FROM information_schema.TABLE_CONSTRAINTS t JOIN information_schema.CHECK_CONSTRAINTS c \
         ON c.CONSTRAINT_SCHEMA = t.CONSTRAINT_SCHEMA AND c.CONSTRAINT_NAME = t.CONSTRAINT_NAME \
         WHERE t.CONSTRAINT_TYPE = 'CHECK' AND t.TABLE_SCHEMA NOT IN {SYSTEM} \
         ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME, t.CONSTRAINT_NAME"
    );
    fetch(pool, "CHECK_CONSTRAINTS", &sql, |mut c| {
        Ok(CheckConstraint {
            table_schema: c.text("table_schema")?,
            table_name: c.text("table_name")?,
            constraint_name: c.text("constraint_name")?,
            check_clause: c.text("check_clause")?,
            enforced: c.flag("enforced")?,
        })
    })
    .await
}

async fn fetch_partitions(pool: &Pool) -> Result<Vec<PartitionRow>, EngineError> {
    let sql = format!(
        "SELECT TABLE_SCHEMA AS table_schema, TABLE_NAME AS table_name, PARTITION_NAME AS partition_name, \
         SUBPARTITION_NAME AS subpartition_name, PARTITION_ORDINAL_POSITION AS partition_ordinal_position, \
         SUBPARTITION_ORDINAL_POSITION AS subpartition_ordinal_position, PARTITION_METHOD AS partition_method, \
         SUBPARTITION_METHOD AS subpartition_method, PARTITION_EXPRESSION AS partition_expression, \
         SUBPARTITION_EXPRESSION AS subpartition_expression, PARTITION_DESCRIPTION AS partition_description, \
         PARTITION_COMMENT AS partition_comment FROM information_schema.PARTITIONS \
         WHERE TABLE_SCHEMA NOT IN {SYSTEM} AND PARTITION_NAME IS NOT NULL \
         ORDER BY TABLE_SCHEMA, TABLE_NAME, PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION"
    );
    fetch(pool, "PARTITIONS", &sql, |mut c| {
        Ok(PartitionRow {
            table_schema: c.text("table_schema")?,
            table_name: c.text("table_name")?,
            partition_name: c.text("partition_name")?,
            subpartition_name: c.opt("subpartition_name")?,
            partition_ordinal_position: c.int("partition_ordinal_position")?,
            subpartition_ordinal_position: c.opt_int("subpartition_ordinal_position")?,
            partition_method: c.text("partition_method")?,
            subpartition_method: c.opt("subpartition_method")?,
            partition_expression: c.opt("partition_expression")?,
            subpartition_expression: c.opt("subpartition_expression")?,
            partition_description: c.opt("partition_description")?,
            partition_comment: c.text("partition_comment")?,
        })
    })
    .await
}

async fn fetch_views(pool: &Pool) -> Result<Vec<ViewRow>, EngineError> {
    let sql = format!(
        "SELECT TABLE_SCHEMA AS table_schema, TABLE_NAME AS table_name, CHECK_OPTION AS check_option, \
         DEFINER AS definer, SECURITY_TYPE AS security_type, CHARACTER_SET_CLIENT AS character_set_client, \
         COLLATION_CONNECTION AS collation_connection FROM information_schema.VIEWS \
         WHERE TABLE_SCHEMA NOT IN {SYSTEM} ORDER BY TABLE_SCHEMA, TABLE_NAME"
    );
    fetch(pool, "VIEWS", &sql, |mut c| {
        Ok(ViewRow {
            table_schema: c.text("table_schema")?,
            table_name: c.text("table_name")?,
            check_option: c.text("check_option")?,
            definer: c.text("definer")?,
            security_type: c.text("security_type")?,
            character_set_client: c.text("character_set_client")?,
            collation_connection: c.text("collation_connection")?,
        })
    })
    .await
}

async fn fetch_view_tables(pool: &Pool) -> Result<Vec<ViewTable>, EngineError> {
    let sql = format!(
        "SELECT VIEW_SCHEMA AS view_schema, VIEW_NAME AS view_name, TABLE_SCHEMA AS table_schema, \
         TABLE_NAME AS table_name FROM information_schema.VIEW_TABLE_USAGE WHERE VIEW_SCHEMA NOT IN {SYSTEM} \
         ORDER BY VIEW_SCHEMA, VIEW_NAME, TABLE_SCHEMA, TABLE_NAME"
    );
    fetch(pool, "VIEW_TABLE_USAGE", &sql, |mut c| {
        Ok(ViewTable {
            view_schema: c.text("view_schema")?,
            view_name: c.text("view_name")?,
            table_schema: c.text("table_schema")?,
            table_name: c.text("table_name")?,
        })
    })
    .await
}

async fn fetch_routines(pool: &Pool, caps: &Capabilities) -> Result<Vec<RoutineRow>, EngineError> {
    let sql = format!(
        "SELECT ROUTINE_SCHEMA AS routine_schema, ROUTINE_NAME AS routine_name, ROUTINE_TYPE AS routine_type, \
         (IS_DETERMINISTIC = 'YES') AS is_deterministic, SQL_DATA_ACCESS AS sql_data_access, \
         SECURITY_TYPE AS security_type, DEFINER AS definer, SQL_MODE AS sql_mode, ROUTINE_COMMENT AS routine_comment, \
         CHARACTER_SET_CLIENT AS character_set_client, COLLATION_CONNECTION AS collation_connection, \
         DATABASE_COLLATION AS database_collation, {} AS external_language FROM information_schema.ROUTINES \
         WHERE ROUTINE_SCHEMA NOT IN {SYSTEM} ORDER BY ROUTINE_SCHEMA, ROUTINE_TYPE, ROUTINE_NAME",
        col(caps, "routines", "EXTERNAL_LANGUAGE")
    );
    fetch(pool, "ROUTINES", &sql, |mut c| {
        Ok(RoutineRow {
            routine_schema: c.text("routine_schema")?,
            routine_name: c.text("routine_name")?,
            routine_type: c.text("routine_type")?,
            is_deterministic: c.flag("is_deterministic")?,
            sql_data_access: c.text("sql_data_access")?,
            security_type: c.text("security_type")?,
            definer: c.text("definer")?,
            sql_mode: c.text("sql_mode")?,
            routine_comment: c.text("routine_comment")?,
            character_set_client: c.text("character_set_client")?,
            collation_connection: c.text("collation_connection")?,
            database_collation: c.text("database_collation")?,
            external_language: c.opt("external_language")?,
        })
    })
    .await
}

async fn fetch_parameters(pool: &Pool) -> Result<Vec<ParameterRow>, EngineError> {
    let sql = format!(
        "SELECT SPECIFIC_SCHEMA AS specific_schema, SPECIFIC_NAME AS specific_name, ROUTINE_TYPE AS routine_type, \
         ORDINAL_POSITION AS ordinal_position, PARAMETER_MODE AS parameter_mode, PARAMETER_NAME AS parameter_name, \
         DTD_IDENTIFIER AS dtd_identifier FROM information_schema.PARAMETERS WHERE SPECIFIC_SCHEMA NOT IN {SYSTEM} \
         ORDER BY SPECIFIC_SCHEMA, ROUTINE_TYPE, SPECIFIC_NAME, ORDINAL_POSITION"
    );
    fetch(pool, "PARAMETERS", &sql, |mut c| {
        Ok(ParameterRow {
            specific_schema: c.text("specific_schema")?,
            specific_name: c.text("specific_name")?,
            routine_type: c.text("routine_type")?,
            ordinal_position: c.int("ordinal_position")?,
            parameter_mode: c.opt("parameter_mode")?,
            parameter_name: c.opt("parameter_name")?,
            dtd_identifier: c.text("dtd_identifier")?,
        })
    })
    .await
}

async fn fetch_triggers(pool: &Pool) -> Result<Vec<TriggerRow>, EngineError> {
    let sql = format!(
        "SELECT TRIGGER_SCHEMA AS trigger_schema, TRIGGER_NAME AS trigger_name, EVENT_OBJECT_TABLE AS event_object_table, \
         ACTION_TIMING AS action_timing, EVENT_MANIPULATION AS event_manipulation, ACTION_ORDER AS action_order, \
         ACTION_STATEMENT AS action_statement, DEFINER AS definer, SQL_MODE AS sql_mode, \
         CHARACTER_SET_CLIENT AS character_set_client, COLLATION_CONNECTION AS collation_connection, \
         DATABASE_COLLATION AS database_collation FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA NOT IN {SYSTEM} \
         ORDER BY TRIGGER_SCHEMA, TRIGGER_NAME"
    );
    fetch(pool, "TRIGGERS", &sql, |mut c| {
        Ok(TriggerRow {
            trigger_schema: c.text("trigger_schema")?,
            trigger_name: c.text("trigger_name")?,
            event_object_table: c.text("event_object_table")?,
            action_timing: c.text("action_timing")?,
            event_manipulation: c.text("event_manipulation")?,
            action_order: c.int("action_order")?,
            action_statement: c.text("action_statement")?,
            definer: c.text("definer")?,
            sql_mode: c.text("sql_mode")?,
            character_set_client: c.text("character_set_client")?,
            collation_connection: c.text("collation_connection")?,
            database_collation: c.text("database_collation")?,
        })
    })
    .await
}

async fn fetch_events(pool: &Pool) -> Result<Vec<EventRow>, EngineError> {
    let sql = format!(
        "SELECT EVENT_SCHEMA AS event_schema, EVENT_NAME AS event_name, EVENT_DEFINITION AS event_definition, \
         CAST(EXECUTE_AT AS CHAR) AS execute_at, CAST(INTERVAL_VALUE AS CHAR) AS interval_value, \
         INTERVAL_FIELD AS interval_field, CAST(STARTS AS CHAR) AS starts, CAST(ENDS AS CHAR) AS ends, \
         STATUS AS status, ON_COMPLETION AS on_completion, EVENT_COMMENT AS event_comment, DEFINER AS definer, \
         TIME_ZONE AS time_zone, SQL_MODE AS sql_mode, CHARACTER_SET_CLIENT AS character_set_client, \
         COLLATION_CONNECTION AS collation_connection, DATABASE_COLLATION AS database_collation \
         FROM information_schema.EVENTS WHERE EVENT_SCHEMA NOT IN {SYSTEM} ORDER BY EVENT_SCHEMA, EVENT_NAME"
    );
    fetch(pool, "EVENTS", &sql, |mut c| {
        Ok(EventRow {
            event_schema: c.text("event_schema")?,
            event_name: c.text("event_name")?,
            event_definition: c.text("event_definition")?,
            execute_at: c.opt("execute_at")?,
            interval_value: c.opt("interval_value")?,
            interval_field: c.opt("interval_field")?,
            starts: c.opt("starts")?,
            ends: c.opt("ends")?,
            status: c.text("status")?,
            on_completion: c.text("on_completion")?,
            event_comment: c.text("event_comment")?,
            definer: c.text("definer")?,
            time_zone: c.text("time_zone")?,
            sql_mode: c.text("sql_mode")?,
            character_set_client: c.text("character_set_client")?,
            collation_connection: c.text("collation_connection")?,
            database_collation: c.text("database_collation")?,
        })
    })
    .await
}

async fn fetch_libraries(pool: &Pool) -> Result<Vec<LibraryRow>, EngineError> {
    let sql = format!(
        "SELECT LIBRARY_SCHEMA AS library_schema, LIBRARY_NAME AS library_name, LIBRARY_DEFINITION AS library_definition, \
         `LANGUAGE` AS language, SQL_MODE AS sql_mode, LIBRARY_COMMENT AS library_comment \
         FROM information_schema.LIBRARIES WHERE LIBRARY_SCHEMA NOT IN {SYSTEM} ORDER BY LIBRARY_SCHEMA, LIBRARY_NAME"
    );
    fetch(pool, "LIBRARIES", &sql, |mut c| {
        Ok(LibraryRow {
            library_schema: c.text("library_schema")?,
            library_name: c.text("library_name")?,
            library_definition: c.text("library_definition")?,
            language: c.text("language")?,
            sql_mode: c.text("sql_mode")?,
            library_comment: c.opt("library_comment")?,
        })
    })
    .await
}

async fn fetch_routine_libraries(pool: &Pool) -> Result<Vec<RoutineLibrary>, EngineError> {
    let sql = format!(
        "SELECT ROUTINE_SCHEMA AS routine_schema, ROUTINE_NAME AS routine_name, ROUTINE_TYPE AS routine_type, \
         LIBRARY_SCHEMA AS library_schema, LIBRARY_NAME AS library_name FROM information_schema.ROUTINE_LIBRARIES \
         WHERE ROUTINE_SCHEMA NOT IN {SYSTEM} ORDER BY ROUTINE_SCHEMA, ROUTINE_TYPE, ROUTINE_NAME, LIBRARY_SCHEMA, LIBRARY_NAME"
    );
    fetch(pool, "ROUTINE_LIBRARIES", &sql, |mut c| {
        Ok(RoutineLibrary {
            routine_schema: c.text("routine_schema")?,
            routine_name: c.text("routine_name")?,
            routine_type: c.text("routine_type")?,
            library_schema: c.text("library_schema")?,
            library_name: c.text("library_name")?,
        })
    })
    .await
}

async fn fetch_tablespaces(pool: &Pool, caps: &Capabilities) -> Result<Vec<TablespaceRow>, EngineError> {
    // 8.0 and later list them in INNODB_TABLESPACES, 5.7 in INNODB_SYS_TABLESPACES
    let (table, general) = if caps.table("information_schema", "innodb_tablespaces") {
        ("INNODB_TABLESPACES", "t.SPACE_TYPE = 'General' AND t.NAME <> 'mysql'")
    } else if caps.table("information_schema", "innodb_sys_tablespaces") {
        ("INNODB_SYS_TABLESPACES", "t.SPACE_TYPE = 'General'")
    } else {
        return Ok(Vec::new());
    };
    let lower = table.to_lowercase();
    let sql = format!(
        "SELECT t.NAME AS name, f.FILE_NAME AS file_name, {} AS encryption, {} AS autoextend_size \
         FROM information_schema.{table} t JOIN information_schema.FILES f ON f.TABLESPACE_NAME = t.NAME \
         WHERE {general} ORDER BY t.NAME",
        prefixed(caps, &lower, "ENCRYPTION"),
        prefixed(caps, &lower, "AUTOEXTEND_SIZE")
    );
    fetch(pool, "INNODB_TABLESPACES", &sql, |mut c| {
        Ok(TablespaceRow {
            name: c.text("name")?,
            file_name: c.opt("file_name")?,
            encryption: c.opt("encryption")?,
            autoextend_size: c.opt_int("autoextend_size")?,
        })
    })
    .await
}

/// `t.COLUMN` when the table has it, `NULL` otherwise.
fn prefixed(caps: &Capabilities, table: &str, column: &str) -> String {
    if caps.column("information_schema", table, column) {
        format!("t.{column}")
    } else {
        "NULL".to_string()
    }
}

async fn fetch_spatial_reference_systems(pool: &Pool) -> Result<Vec<SpatialReferenceSystemRow>, EngineError> {
    // only the ones made on the server: MySQL ships the rest
    let sql = "SELECT SRS_NAME AS srs_name, SRS_ID AS srs_id, ORGANIZATION AS organization, \
               ORGANIZATION_COORDSYS_ID AS organization_coordsys_id, DEFINITION AS definition, DESCRIPTION AS description \
               FROM information_schema.ST_SPATIAL_REFERENCE_SYSTEMS \
               WHERE SRS_ID BETWEEN 32768 AND 59999999 OR SRS_ID BETWEEN 70000000 AND 1999999999 OR SRS_ID >= 2147483648 \
               ORDER BY SRS_ID";
    fetch(pool, "ST_SPATIAL_REFERENCE_SYSTEMS", sql, |mut c| {
        Ok(SpatialReferenceSystemRow {
            srs_name: c.text("srs_name")?,
            srs_id: c.int("srs_id")?,
            organization: c.opt("organization")?,
            organization_coordsys_id: c.opt_int("organization_coordsys_id")?,
            definition: c.text("definition")?,
            description: c.opt("description")?,
        })
    })
    .await
}

async fn fetch_resource_groups(pool: &Pool) -> Result<Vec<ResourceGroupRow>, EngineError> {
    let sql = "SELECT RESOURCE_GROUP_NAME AS resource_group_name, RESOURCE_GROUP_TYPE AS resource_group_type, \
               RESOURCE_GROUP_ENABLED AS resource_group_enabled, CAST(VCPU_IDS AS CHAR) AS vcpu_ids, \
               THREAD_PRIORITY AS thread_priority FROM information_schema.RESOURCE_GROUPS \
               WHERE RESOURCE_GROUP_NAME NOT IN ('USR_default', 'SYS_default') ORDER BY RESOURCE_GROUP_NAME";
    fetch(pool, "RESOURCE_GROUPS", sql, |mut c| {
        Ok(ResourceGroupRow {
            resource_group_name: c.text("resource_group_name")?,
            resource_group_type: c.text("resource_group_type")?,
            resource_group_enabled: c.flag("resource_group_enabled")?,
            vcpu_ids: c.opt("vcpu_ids")?,
            thread_priority: c.int("thread_priority")?,
        })
    })
    .await
}

async fn fetch_compression_dictionaries(
    pool: &Pool,
    caps: &Capabilities,
) -> Result<Vec<CompressionDictionaryRow>, EngineError> {
    // Percona Server: COMPRESSION_DICTIONARY on 8.0, XTRADB_ZIP_DICT on 5.7
    let sql = if caps.table("information_schema", "compression_dictionary") {
        "SELECT DICT_NAME AS name, CAST(DICT_DATA AS CHAR) AS data FROM information_schema.COMPRESSION_DICTIONARY ORDER BY DICT_NAME"
    } else if caps.table("information_schema", "xtradb_zip_dict") {
        "SELECT name AS name, CAST(zip_dict AS CHAR) AS data FROM information_schema.XTRADB_ZIP_DICT ORDER BY name"
    } else {
        return Ok(Vec::new());
    };
    fetch(pool, "COMPRESSION_DICTIONARY", sql, |mut c| {
        Ok(CompressionDictionaryRow {
            name: c.text("name")?,
            data: c.text("data")?,
        })
    })
    .await
}

/// A level of `information_schema`'s privilege tables; the columns the level lacks are asked as `NULL`.
async fn fetch_grants(
    pool: &Pool,
    table: &'static str,
    schema: &str,
    name: &str,
    column: &str,
) -> Result<Vec<GrantRow>, EngineError> {
    let sql = format!(
        "SELECT GRANTEE AS grantee, {schema} AS table_schema, {name} AS table_name, {column} AS column_name, \
         PRIVILEGE_TYPE AS privilege_type, (IS_GRANTABLE = 'YES') AS is_grantable \
         FROM information_schema.{table} ORDER BY GRANTEE, PRIVILEGE_TYPE"
    );
    let rows = fetch(pool, table, &sql, |mut c| {
        Ok(GrantRow {
            grantee: c.text("grantee")?,
            table_schema: c.opt("table_schema")?,
            table_name: c.opt("table_name")?,
            column_name: c.opt("column_name")?,
            privilege_type: c.text("privilege_type")?,
            is_grantable: c.flag("is_grantable")?,
        })
    })
    .await?;
    // the server's own accounts' privileges are the server's
    Ok(rows
        .into_iter()
        .filter(|g| split_grantee(&g.grantee).is_none_or(|(user, _)| !is_system_account(&user)))
        .collect())
}

/// `'user'@'host'` as the user and the host: each quoted with `'`, a quote inside written twice.
pub(crate) fn split_grantee(grantee: &str) -> Option<(String, String)> {
    let rest = grantee.strip_prefix('\'')?;
    let mut user = String::new();
    let mut chars = rest.chars().peekable();
    loop {
        match chars.next()? {
            '\'' if chars.peek() == Some(&'\'') => {
                chars.next();
                user.push('\'');
            }
            '\'' => break,
            c => user.push(c),
        }
    }
    let host_part: String = chars.collect();
    let host = host_part.strip_prefix("@'")?.strip_suffix('\'')?.replace("''", "'");
    Some((user, host))
}

async fn fetch_routine_privileges(pool: &Pool) -> Result<Vec<RoutinePrivilege>, EngineError> {
    let sql = format!(
        "SELECT User AS user, Host AS host, Db AS db, Routine_name AS routine_name, Routine_type AS routine_type, \
         CAST(Proc_priv AS CHAR) AS proc_priv FROM mysql.procs_priv WHERE Db NOT IN {SYSTEM} \
         ORDER BY User, Host, Db, Routine_name"
    );
    let rows = fetch(pool, "procs_priv", &sql, |mut c| {
        Ok(RoutinePrivilege {
            user: c.text("user")?,
            host: c.text("host")?,
            db: c.text("db")?,
            routine_name: c.text("routine_name")?,
            routine_type: c.text("routine_type")?,
            proc_priv: c.text("proc_priv")?,
        })
    })
    .await?;
    Ok(rows.into_iter().filter(|r| !is_system_account(&r.user)).collect())
}

async fn fetch_proxy_privileges(pool: &Pool) -> Result<Vec<ProxyPrivilege>, EngineError> {
    let sql = "SELECT User AS user, Host AS host, Proxied_user AS proxied_user, Proxied_host AS proxied_host, \
               With_grant AS with_grant FROM mysql.proxies_priv ORDER BY User, Host, Proxied_user, Proxied_host";
    let rows = fetch(pool, "proxies_priv", sql, |mut c| {
        Ok(ProxyPrivilege {
            user: c.text("user")?,
            host: c.text("host")?,
            proxied_user: c.text("proxied_user")?,
            proxied_host: c.text("proxied_host")?,
            with_grant: c.flag("with_grant")?,
        })
    })
    .await?;
    Ok(rows
        .into_iter()
        .filter(|r| !is_system_account(&r.user) && !is_system_account(&r.proxied_user))
        .collect())
}

async fn fetch_accounts(pool: &Pool) -> Result<Vec<AccountRow>, EngineError> {
    let sql = "SELECT User AS user, Host AS host FROM mysql.user \
               WHERE NOT (User = 'root' OR User LIKE 'mysql.%' OR User LIKE 'percona.%') ORDER BY User, Host";
    fetch(pool, "mysql.user", sql, |mut c| {
        Ok(AccountRow {
            user: c.text("user")?,
            host: c.text("host")?,
        })
    })
    .await
}

async fn fetch_role_edges(pool: &Pool) -> Result<Vec<RoleEdge>, EngineError> {
    let sql = "SELECT FROM_USER AS from_user, FROM_HOST AS from_host, TO_USER AS to_user, TO_HOST AS to_host, \
               (WITH_ADMIN_OPTION = 'Y') AS with_admin_option FROM mysql.role_edges ORDER BY TO_USER, TO_HOST, FROM_USER, FROM_HOST";
    let rows = fetch(pool, "role_edges", sql, |mut c| {
        Ok(RoleEdge {
            from_user: c.text("from_user")?,
            from_host: c.text("from_host")?,
            to_user: c.text("to_user")?,
            to_host: c.text("to_host")?,
            with_admin_option: c.flag("with_admin_option")?,
        })
    })
    .await?;
    Ok(rows
        .into_iter()
        .filter(|r| !is_system_account(&r.from_user) && !is_system_account(&r.to_user))
        .collect())
}

async fn fetch_default_roles(pool: &Pool) -> Result<Vec<DefaultRole>, EngineError> {
    let sql = "SELECT USER AS user, HOST AS host, DEFAULT_ROLE_USER AS default_role_user, \
               DEFAULT_ROLE_HOST AS default_role_host FROM mysql.default_roles ORDER BY USER, HOST";
    let rows = fetch(pool, "default_roles", sql, |mut c| {
        Ok(DefaultRole {
            user: c.text("user")?,
            host: c.text("host")?,
            default_role_user: c.text("default_role_user")?,
            default_role_host: c.text("default_role_host")?,
        })
    })
    .await?;
    Ok(rows.into_iter().filter(|r| !is_system_account(&r.user)).collect())
}

async fn fetch_servers(pool: &Pool) -> Result<Vec<ServerRow>, EngineError> {
    let sql = "SELECT Server_name AS server_name, Host AS host, Db AS db, Username AS username, Port AS port, \
               Socket AS socket, Wrapper AS wrapper, Owner AS owner FROM mysql.servers ORDER BY Server_name";
    fetch(pool, "mysql.servers", sql, |mut c| {
        Ok(ServerRow {
            server_name: c.text("server_name")?,
            host: c.text("host")?,
            db: c.text("db")?,
            username: c.text("username")?,
            port: c.int("port")?,
            socket: c.text("socket")?,
            wrapper: c.text("wrapper")?,
            owner: c.text("owner")?,
        })
    })
    .await
}

async fn fetch_loadable_functions(pool: &Pool) -> Result<Vec<LoadableFunctionRow>, EngineError> {
    let sql = "SELECT name AS name, ret AS ret, dl AS dl, `type` AS kind FROM mysql.func ORDER BY name";
    fetch(pool, "mysql.func", sql, |mut c| {
        Ok(LoadableFunctionRow {
            name: c.text("name")?,
            ret: c.int("ret")?,
            dl: c.text("dl")?,
            kind: c.text("kind")?,
        })
    })
    .await
}

async fn fetch_components(pool: &Pool) -> Result<Vec<String>, EngineError> {
    let sql = format!(
        "SELECT component_urn AS component_urn FROM mysql.component WHERE component_urn <> '{SYSTEM_COMPONENT}' \
         ORDER BY component_urn"
    );
    fetch(pool, "mysql.component", &sql, |mut c| c.text("component_urn")).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_server_has_the_tables_and_columns_its_probe_found() {
        let caps = Capabilities::of(&[
            ("information_schema", "SCHEMATA", "DEFAULT_ENCRYPTION"),
            ("information_schema", "CHECK_CONSTRAINTS", "CHECK_CLAUSE"),
            ("mysql", "role_edges", "FROM_USER"),
        ]);
        assert!(caps.table("information_schema", "check_constraints"));
        assert!(caps.column("information_schema", "schemata", "default_encryption"));
        assert!(!caps.table("information_schema", "libraries"));
        assert!(caps.table("mysql", "ROLE_EDGES"));
        assert_eq!(col(&caps, "schemata", "DEFAULT_ENCRYPTION"), "DEFAULT_ENCRYPTION");
        assert_eq!(col(&caps, "schemata", "NO_SUCH_COLUMN"), "NULL");
    }

    #[test]
    fn the_servers_own_accounts_are_not_a_designs() {
        for own in [
            "root",
            "mysql.sys",
            "mysql.session",
            "mysql.infoschema",
            "percona.telemetry",
        ] {
            assert!(is_system_account(own), "{own}");
        }
        for theirs in ["app", "report", "mysqlx", "perconax", ""] {
            assert!(!is_system_account(theirs), "{theirs}");
        }
    }

    #[test]
    fn a_grantee_splits_into_its_user_and_host() {
        assert_eq!(split_grantee("'app'@'%'"), Some(("app".into(), "%".into())));
        assert_eq!(
            split_grantee("''@'localhost'"),
            Some((String::new(), "localhost".into()))
        );
        assert_eq!(
            split_grantee("'o''neil'@'10.0.%'"),
            Some(("o'neil".into(), "10.0.%".into()))
        );
        assert_eq!(split_grantee("app@%"), None);
    }
}
