//! The schema model: the one structure every part of Schema Forge works on (docs/model.md).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::{DataType, Id};

/// The file format this crate reads and writes.
pub const FORMAT: u32 = 1;

/// The database a schema is designed for. One per schema; another target is a conversion.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Target {
    Mysql,
    Postgres,
    Iceberg,
}

/// A whole schema.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Schema {
    pub format: u32,
    pub target: Target,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub namespaces: Vec<Namespace>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub areas: Vec<Area>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tables: Vec<Table>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub relationships: Vec<Relationship>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub views: Vec<View>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sequences: Vec<Sequence>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub types: Vec<TypeDef>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub kept: Vec<Kept>,
}

impl Schema {
    /// An empty schema for `target`.
    #[must_use]
    pub fn new(target: Target) -> Self {
        Self {
            format: FORMAT,
            target,
            namespaces: Vec::new(),
            areas: Vec::new(),
            tables: Vec::new(),
            relationships: Vec::new(),
            views: Vec::new(),
            sequences: Vec::new(),
            types: Vec::new(),
            kept: Vec::new(),
        }
    }
}

/// Where objects live: a PostgreSQL schema, a MySQL database, an Iceberg namespace (nested through `parent`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Namespace {
    pub id: Id,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
}

/// A group of tables and views shown together in the perspectives.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Area {
    pub id: Id,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub colour: Option<String>,
}

/// A table.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Table {
    pub id: Id,
    pub namespace: Id,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    /// Design notes kept with it, written as comment lines before it (why it is shaped as it is).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub area: Option<Id>,
    pub columns: Vec<Column>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary_key: Option<PrimaryKey>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub uniques: Vec<Unique>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub checks: Vec<Check>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub indexes: Vec<Index>,
    /// Patterns the table follows, with their settings (`scd2`: its business key).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub patterns: BTreeMap<String, serde_json::Value>,
    /// PostgreSQL, a designed partition only: its parent and bounds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partition_of: Option<PartitionOf>,
    #[serde(default, skip_serializing_if = "TableOptions::is_empty")]
    pub options: TableOptions,
}

/// A column.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Column {
    pub id: Id,
    pub name: String,
    #[serde(rename = "type")]
    pub data_type: DataType,
    pub nullable: bool,
    /// The default expression, exactly as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<String>,
    /// Iceberg (format 3): the value for rows written before the column existed, and for new rows without one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initial_default: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub write_default: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generated: Option<Generated>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<Identity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    /// Iceberg: the column's permanent number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub field_id: Option<i32>,
    /// MySQL `ON UPDATE CURRENT_TIMESTAMP` and the like, as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_update: Option<String>,
}

/// A generated column.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Generated {
    pub expression: String,
    pub stored: bool,
}

/// An identity column: PostgreSQL `GENERATED … AS IDENTITY`, MySQL `AUTO_INCREMENT`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    /// PostgreSQL `ALWAYS` (else `BY DEFAULT`); unused on MySQL.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub always: bool,
    /// PostgreSQL sequence options, as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<String>,
}

/// A table's primary key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PrimaryKey {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub columns: Vec<Id>,
}

/// A unique key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Unique {
    pub id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub columns: Vec<Id>,
    /// PostgreSQL 15+ `NULLS NOT DISTINCT` when false.
    #[serde(default = "yes", skip_serializing_if = "is_yes")]
    pub nulls_distinct: bool,
}

/// A check constraint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Check {
    pub id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// The expression, exactly as written.
    pub expression: String,
}

/// An index.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Index {
    pub id: Id,
    pub name: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub unique: bool,
    pub parts: Vec<IndexPart>,
    /// PostgreSQL `btree`, `gin`, …; MySQL `btree`, `hash`, `fulltext`, `spatial`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    /// PostgreSQL covering columns.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub include: Vec<Id>,
    /// PostgreSQL partial index condition, as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "where")]
    pub predicate: Option<String>,
}

/// One part of an index: a column or an expression.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct IndexPart {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expression: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub direction: Option<Direction>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nulls: Option<Nulls>,
    /// MySQL prefix length.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub length: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Asc,
    Desc,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Nulls {
    First,
    Last,
}

/// A designed partition's parent and bounds (PostgreSQL).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartitionOf {
    pub parent: Id,
    /// `FOR VALUES …` or `DEFAULT`, exactly as written.
    pub bounds: String,
}

/// A relationship: a foreign key the database enforces, or a logical one Schema Forge draws and checks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Relationship {
    pub id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub from: Ends,
    pub to: Ends,
    pub enforced: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_delete: Option<Action>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_update: Option<Action>,
    /// PostgreSQL `DEFERRABLE …`, as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deferrable: Option<String>,
    /// PostgreSQL `MATCH FULL` and the like, as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub match_kind: Option<String>,
}

/// One end of a relationship: a table and its columns, in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ends {
    pub table: Id,
    pub columns: Vec<Id>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    NoAction,
    Restrict,
    Cascade,
    SetNull,
    SetDefault,
}

/// A database view.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct View {
    pub id: Id,
    pub namespace: Id,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    /// Design notes kept with it, written as comment lines before it (why it is shaped as it is).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub area: Option<Id>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub columns: Vec<ViewColumn>,
    /// The `SELECT`, exactly as written.
    pub definition: String,
    /// The tables and views it reads, found by parsing the definition.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reads: Vec<Id>,
    #[serde(default, skip_serializing_if = "ViewOptions::is_empty")]
    pub options: ViewOptions,
}

/// A view's column, when it is known.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ViewColumn {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "type")]
    pub data_type: Option<DataType>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
}

/// A PostgreSQL sequence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sequence {
    pub id: Id,
    pub namespace: Id,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "type")]
    pub data_type: Option<DataType>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub increment: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache: Option<i64>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cycle: bool,
    /// The column that owns it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owned_by: Option<Id>,
}

/// A PostgreSQL user-defined type. (Its kind is flattened in, which serde cannot combine with refusing unknown
/// fields; the kind's own variants still refuse them.)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TypeDef {
    pub id: Id,
    pub namespace: Id,
    pub name: String,
    #[serde(flatten)]
    pub kind: TypeKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
}

/// What a user-defined type is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum TypeKind {
    /// Values in their declared order.
    Enum {
        values: Vec<String>,
    },
    Domain {
        base: Box<DataType>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        default: Option<String>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        not_null: bool,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        checks: Vec<String>,
    },
    Composite {
        fields: Vec<CompositeField>,
    },
}

/// A field of a PostgreSQL composite type.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CompositeField {
    pub name: String,
    #[serde(rename = "type")]
    pub data_type: DataType,
}

/// A statement carried through exactly as read, written back in its place.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Kept {
    pub id: Id,
    pub kind: KeptKind,
    pub text: String,
    /// The object it followed in the dump; `None` for the start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<Id>,
    /// Objects it names, where the parser can tell.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub refers_to: Vec<Id>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum KeptKind {
    Function,
    Trigger,
    Grant,
    Extension,
    Setting,
    Partitions,
    Other,
}

/// A table's options, by target; only the schema's own target's are set.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TableOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mysql: Option<MysqlTable>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub postgres: Option<PostgresTable>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub iceberg: Option<IcebergTable>,
}

impl TableOptions {
    fn is_empty(&self) -> bool {
        self.mysql.is_none() && self.postgres.is_none() && self.iceberg.is_none()
    }
}

/// MySQL table options.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MysqlTable {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub engine: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub charset: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row_format: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_increment: Option<u64>,
    /// `PARTITION BY …`, exactly as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partitioning: Option<String>,
    /// Any other table option, in order, as written.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub other: Vec<String>,
}

/// PostgreSQL table options.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PostgresTable {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tablespace: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub unlogged: bool,
    /// `PARTITION BY …`, exactly as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partition_by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partition_policy: Option<PartitionPolicy>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub inherits: Vec<Id>,
    /// `WITH (…)` storage parameters, as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub storage: Option<String>,
}

/// How a partitioned table's partitions come and go (docs/model.md, Decided).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartitionPolicy {
    /// `1 day`, `1 month`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interval: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retention: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub premake: Option<u32>,
    /// `pg_partman`, `application`, `schema-forge`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub managed_by: Option<String>,
    /// An imported run of partitions, held as one: its statements are kept verbatim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub series: Option<PartitionSeries>,
}

/// A run of partitions recognised on import.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartitionSeries {
    pub interval: String,
    pub first: String,
    pub last: String,
    pub count: u32,
    /// The kept statement holding them.
    pub kept: Id,
}

/// Iceberg table options.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct IcebergTable {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format_version: Option<u8>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub identifier_fields: Vec<Id>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub partition_spec: Vec<PartitionField>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sort_order: Vec<SortField>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub properties: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub location: Option<String>,
}

/// A partition field: a source column and a transform (`identity`, `bucket[16]`, `day`, …).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartitionField {
    pub source: Id,
    pub transform: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// A sort field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SortField {
    pub source: Id,
    #[serde(default = "identity", skip_serializing_if = "is_identity")]
    pub transform: String,
    pub direction: Direction,
    pub nulls: Nulls,
}

/// A view's options, by target.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ViewOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mysql: Option<MysqlView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub postgres: Option<PostgresView>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub iceberg: Option<IcebergView>,
}

impl ViewOptions {
    fn is_empty(&self) -> bool {
        self.mysql.is_none() && self.postgres.is_none() && self.iceberg.is_none()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MysqlView {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub algorithm: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub definer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sql_security: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_option: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PostgresView {
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub materialized: bool,
    /// Materialized views: `WITH NO DATA` when false.
    #[serde(default = "yes", skip_serializing_if = "is_yes")]
    pub with_data: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_option: Option<String>,
    /// `WITH (…)` options such as `security_barrier`, as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub with: Option<String>,
    /// Indexes on a materialized view.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub indexes: Vec<Index>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct IcebergView {
    /// The dialect `definition` is written in (`spark`, `trino`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dialect: Option<String>,
    /// The same definition in other dialects.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub representations: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_catalog: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub default_namespace: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u32>,
}

#[allow(clippy::unnecessary_wraps)]
const fn yes() -> bool {
    true
}

#[allow(clippy::trivially_copy_pass_by_ref)]
const fn is_yes(b: &bool) -> bool {
    *b
}

fn identity() -> String {
    "identity".to_string()
}

fn is_identity(s: &str) -> bool {
    s == "identity"
}
