//! The section layout: one shape for what every engine stores on the parts of a schema.
//!
//! Every engine fills the same slots, and leaves out the ones its database does not have: a table's keys, checks,
//! indexes, partitioning and order; a view's query; a sequence; the schema's own types; a column's default, identity
//! and generated expression; a link's actions; what the schema kept as written. What belongs to one database alone has
//! one home, the `options` of the element it is about, which that engine describes and checks. A slot the layout does
//! not have is refused, so no engine grows a storage of its own.
//!
//! The model stores a section as JSON and never reads it; an engine reads it with [`read`] into these shapes and writes
//! it back with [`write`]. Everything here is made with `Default` and set by field, so a slot added later breaks no
//! engine:
//!
//! ```
//! use schema_forge_engine::sections::{Key, ObjectSection, write};
//! use schema_forge_model::Id;
//!
//! let mut table = ObjectSection::default();
//! let mut pk = Key::default();
//! pk.name = Some("orders_pkey".into());
//! pk.columns = vec![Id::try_from("c_orders_id").unwrap()];
//! table.keys.primary = Some(pk);
//! let section = write(&table);
//! assert_eq!(serde_json::Value::Object(section)["keys"]["primary"]["name"], "orders_pkey");
//! ```

use schema_forge_model::{Id, Section};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

/// What belongs to one database alone, on the element it is about: the engine describes and checks it.
pub type Options = serde_json::Map<String, serde_json::Value>;

/// The version of this layout. A schema written with a later layout says so in its schema section, and a build that
/// knows an earlier one refuses it whole ([`layout_of`]) instead of reading it with something dropped.
pub const LAYOUT: u32 = 1;

/// Whether this build can read the sections of a schema whose schema section is `section`.
///
/// # Errors
/// When the schema was written with a later layout than this build knows.
pub fn layout_of(section: &Section) -> Result<u32, String> {
    let layout = match section.get("layout") {
        None => LAYOUT,
        Some(v) => v
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .ok_or_else(|| format!("the section layout `{v}` is not a version"))?,
    };
    if layout > LAYOUT {
        return Err(format!(
            "this schema was written with section layout {layout}; this build of Schema Forge reads up to {LAYOUT}: \
             open it with a newer one"
        ));
    }
    Ok(layout)
}

/// The shapes of the layout: the sections of a schema's parts. Only this module's types are layouts, so [`read`] and
/// [`write`] take nothing else.
pub trait Layout: Serialize + DeserializeOwned + Default + sealed::Sealed {}

mod sealed {
    pub trait Sealed {}
}

macro_rules! layouts {
    ($($t:ty),* $(,)?) => {
        $(impl sealed::Sealed for $t {} impl Layout for $t {})*
    };
}

layouts!(SchemaSection, NamespaceSection, ObjectSection, ColumnSection, LinkSection);

/// Reads a part's section in the layout `T`; an empty section is `T`'s default.
///
/// # Errors
/// When the section does not follow the layout: a slot it does not have, a slot of the wrong shape, or (for the
/// schema's section) a later layout than this build knows.
pub fn read<T: Layout>(section: &Section) -> Result<T, String> {
    if section.is_empty() {
        return Ok(T::default());
    }
    serde_json::from_value(serde_json::Value::Object(section.clone())).map_err(|e| e.to_string())
}

/// A section in the layout, as the model stores it: slots left empty are left out.
///
/// # Panics
/// Never: every layout is a struct of strings, numbers, booleans, ids and string-keyed maps, which always become a
/// JSON object.
#[must_use]
pub fn write<T: Layout>(layout: &T) -> Section {
    match serde_json::to_value(layout) {
        Ok(serde_json::Value::Object(map)) => map,
        other => unreachable!("a section layout always becomes a JSON object, not {other:?}"),
    }
}

fn is_false(b: &bool) -> bool {
    !*b
}

fn is_true(b: &bool) -> bool {
    *b
}

const fn yes() -> bool {
    true
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

const fn current_layout() -> u32 {
    LAYOUT
}

fn is_current_layout(n: &u32) -> bool {
    *n == LAYOUT
}

fn known_layout<'de, D: serde::Deserializer<'de>>(d: D) -> Result<u32, D::Error> {
    let layout = u32::deserialize(d)?;
    if layout > LAYOUT {
        return Err(serde::de::Error::custom(format!(
            "this schema was written with section layout {layout}; this build of Schema Forge reads up to {LAYOUT}: \
             open it with a newer one"
        )));
    }
    Ok(layout)
}

/// The schema as a whole.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct SchemaSection {
    /// The version of this layout the schema was written with; [`LAYOUT`] when it says none. A later one is refused as
    /// it is read.
    #[serde(default = "current_layout", skip_serializing_if = "is_current_layout", deserialize_with = "known_layout")]
    pub layout: u32,
    /// The engine's own storage version: which version of the engine wrote the options in this schema, so a later
    /// engine reads what an earlier one wrote. Zero when the engine has never changed how it stores them.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub format: u32,
    /// What the schema holds that the model does not describe, kept exactly as written, in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub kept: Vec<Kept>,
    /// What the database needs installed for this schema (extensions, plugins), by name.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub requires: Vec<String>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

impl Default for SchemaSection {
    fn default() -> Self {
        Self { layout: LAYOUT, format: 0, kept: Vec::new(), requires: Vec::new(), options: Options::new() }
    }
}

/// Something read and kept exactly as written (a function, a trigger, a grant), and where it goes back.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Kept {
    /// What kind of thing it is, in the engine's words (`function`, `trigger`, `grant`, `other`).
    pub kind: String,
    pub text: String,
    /// The part it comes after when written: it goes right after that part's definition; `None` is the start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<Id>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// A namespace.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct NamespaceSection {
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// An object: the slots of every kind, each kind filling its own (a table its keys and indexes, a view its query, a
/// sequence its sequence).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct ObjectSection {
    #[serde(default, skip_serializing_if = "Keys::is_empty")]
    pub keys: Keys,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub checks: Vec<Check>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub indexes: Vec<Index>,
    /// How the table is split into partitions.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partitioning: Option<Partitioning>,
    /// The table this one is a partition of, and its bounds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partition_of: Option<PartitionOf>,
    /// The order rows are written in (a sort order, a clustering).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub order: Vec<OrderField>,
    /// A view's query, as written in the engine's SQL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sequence: Option<Sequence>,
    /// An enum's values, in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub values: Vec<String>,
    /// A domain: the type it narrows, its default, and whether it may be null (its checks are in `checks`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub domain: Option<Domain>,
    /// A composite type's fields.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fields: Vec<Field>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// A table's keys.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Keys {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary: Option<Key>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unique: Vec<Key>,
    /// The columns that identify a row without a constraint enforcing it (a lake table's identifier fields).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub identifier: Vec<Id>,
}

impl Keys {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.primary.is_none() && self.unique.is_empty() && self.identifier.is_empty()
    }
}

/// A primary key or a unique: its columns in order.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Key {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub columns: Vec<Id>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// A check: an expression in the engine's SQL every row satisfies.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Check {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub expression: String,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// An index.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Index {
    pub name: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub unique: bool,
    /// How it is built, in the engine's words (`btree`, `gin`, `hash`); `None` is the engine's default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    pub parts: Vec<IndexPart>,
    /// Columns carried in the index without being part of its order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub include: Vec<Id>,
    /// The rows it covers, for a partial index: a condition in the engine's SQL.
    #[serde(default, rename = "where", skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// One part of an index: a column or an expression.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct IndexPart {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expression: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub direction: Option<Direction>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nulls: Option<Nulls>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[non_exhaustive]
pub enum Direction {
    Asc,
    Desc,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[non_exhaustive]
pub enum Nulls {
    First,
    Last,
}

/// How a table is split into partitions: by what, and, where the partitions are defined in the table itself, the
/// partitions.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Partitioning {
    /// The way rows are split, in the engine's words (`range`, `list`, `hash`); `None` when each field says its own
    /// transform.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub strategy: Option<String>,
    pub by: Vec<PartField>,
    /// Partitions defined in the table itself.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub partitions: Vec<Partition>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// What a table is partitioned by: a column or an expression, through a transform (`day`, `bucket[16]`).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct PartField {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expression: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transform: Option<String>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// A partition defined in its table: its name and bounds in the engine's SQL.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Partition {
    pub name: String,
    pub bounds: String,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// The table a partition belongs to, and the rows it holds, in the engine's SQL. Made with [`PartitionOf::new`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct PartitionOf {
    pub parent: Id,
    pub bounds: String,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// One field of the order rows are written in. Made with [`OrderField::new`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct OrderField {
    pub column: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transform: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub direction: Option<Direction>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nulls: Option<Nulls>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

impl PartitionOf {
    #[must_use]
    pub fn new(parent: Id, bounds: impl Into<String>) -> Self {
        Self { parent, bounds: bounds.into(), options: Options::new() }
    }
}

impl OrderField {
    /// By `column` as it is, ascending, nulls where the engine puts them.
    #[must_use]
    pub fn new(column: Id) -> Self {
        Self { column, transform: None, direction: None, nulls: None, options: Options::new() }
    }
}

/// A sequence.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Sequence {
    /// Its type, as the engine writes it.
    #[serde(default, rename = "type", skip_serializing_if = "Option::is_none")]
    pub data_type: Option<String>,
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
    #[serde(default, skip_serializing_if = "is_false")]
    pub cycle: bool,
    /// The column that owns it: dropped with it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owned_by: Option<Id>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// A domain: a type narrowed by a default, a not null and checks. By default it may hold null.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Domain {
    /// The type it narrows, as the engine writes it.
    pub base: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<String>,
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub null: bool,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

impl Default for Domain {
    fn default() -> Self {
        Self { base: String::new(), default: None, null: true, options: Options::new() }
    }
}

/// A field of a composite type.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Field {
    pub name: String,
    /// Its type, as the engine writes it.
    #[serde(rename = "type")]
    pub data_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// A column.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct ColumnSection {
    /// Its default, an expression in the engine's SQL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<Identity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generated: Option<Generated>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// A column the database numbers itself.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Identity {
    /// Whether a value can never be given (`ALWAYS`), or only when none is (`BY DEFAULT`).
    #[serde(default, skip_serializing_if = "is_false")]
    pub always: bool,
    /// How it numbers, as a sequence does; `None` is the engine's default.
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
    #[serde(default, skip_serializing_if = "is_false")]
    pub cycle: bool,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// A column computed from others.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Generated {
    /// An expression in the engine's SQL.
    pub expression: String,
    /// Whether it is computed when written and stored, or computed when read.
    #[serde(default, skip_serializing_if = "is_false")]
    pub stored: bool,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

/// A link: how the engine holds it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct LinkSection {
    /// Whether the database enforces it (a foreign key), or it is a link the design only draws.
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub enforced: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_delete: Option<Action>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_update: Option<Action>,
    /// How a key of several columns with some null matches, in the engine's words (`full`, `simple`).
    #[serde(default, rename = "match", skip_serializing_if = "Option::is_none")]
    pub match_kind: Option<String>,
    /// Whether it may be checked at the end of a transaction, and whether it is by default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deferrable: Option<Deferrable>,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

impl Default for LinkSection {
    fn default() -> Self {
        Self {
            enforced: true,
            on_delete: None,
            on_update: None,
            match_kind: None,
            deferrable: None,
            options: Options::new(),
        }
    }
}

/// What happens to a link's rows when the row they point at is deleted or its key changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum Action {
    NoAction,
    Restrict,
    Cascade,
    SetNull,
    SetDefault,
}

/// A link checked at the end of a transaction.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[non_exhaustive]
pub struct Deferrable {
    /// Whether it is checked at the end of the transaction unless said otherwise.
    #[serde(default, skip_serializing_if = "is_false")]
    pub initially_deferred: bool,
    #[serde(default, skip_serializing_if = "Options::is_empty")]
    pub options: Options,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn section(v: serde_json::Value) -> Section {
        match v {
            serde_json::Value::Object(m) => m,
            _ => Section::new(),
        }
    }

    #[test]
    fn a_section_reads_and_writes_back_the_same() {
        let s = section(json!({
            "keys": { "primary": { "name": "orders_pkey", "columns": ["c_orders_id"] },
                      "unique": [{ "columns": ["c_orders_no"], "options": { "nulls_not_distinct": true } }] },
            "checks": [{ "expression": "total >= 0" }],
            "indexes": [{ "name": "orders_no_idx", "method": "btree",
                          "parts": [{ "expression": "lower(order_no)", "direction": "desc", "nulls": "last" }],
                          "include": ["c_orders_total"], "where": "valid_to IS NULL" }],
            "partitioning": { "strategy": "range", "by": [{ "column": "c_orders_at" }] },
            "options": { "fillfactor": 70 }
        }));
        let table: ObjectSection = read(&s).expect("it follows the layout");
        assert_eq!(table.indexes[0].condition.as_deref(), Some("valid_to IS NULL"));
        assert_eq!(table.indexes[0].parts[0].direction, Some(Direction::Desc));
        assert_eq!(write(&table), s);
    }

    #[test]
    fn a_slot_the_layout_does_not_have_is_refused() {
        let e = read::<ObjectSection>(&section(json!({ "storage_engine": "heap" }))).unwrap_err();
        assert!(e.contains("unknown field `storage_engine`"), "{e}");
        let e = read::<ColumnSection>(&section(json!({ "identity": { "always": true, "seed": 1 } }))).unwrap_err();
        assert!(e.contains("unknown field `seed`"), "what is the database's alone goes in options: {e}");
        let c: ColumnSection =
            read(&section(json!({ "identity": { "always": true, "start": 10, "increment": 5 } }))).expect("typed");
        assert_eq!(c.identity.map(|i| (i.start, i.increment)), Some((Some(10), Some(5))), "numbered as a sequence is");
    }

    #[test]
    fn empty_slots_are_left_out_and_defaults_are_the_usual_case() {
        assert_eq!(write(&ObjectSection::default()), Section::new());
        assert_eq!(write(&LinkSection::default()), Section::new(), "an enforced link with no actions says nothing");
        let link: LinkSection = read(&Section::new()).expect("empty");
        assert!(link.enforced);
        let not: LinkSection = read(&section(json!({ "enforced": false, "on_delete": "set_null" }))).expect("a link");
        assert_eq!((not.enforced, not.on_delete), (false, Some(Action::SetNull)));
        let d: Domain = serde_json::from_value(json!({ "base": "numeric(18,2)" })).expect("a domain");
        assert!(d.null, "a domain may hold null unless it says not");
        assert!(Domain::default().null, "built in code, the same");
        assert_eq!(write(&SchemaSection::default()), Section::new(), "the current layout is not written out");
    }

    #[test]
    fn a_schema_written_with_a_later_layout_is_refused_whole() {
        assert_eq!(layout_of(&Section::new()), Ok(LAYOUT));
        let later = section(json!({ "layout": LAYOUT + 1 }));
        let e = layout_of(&later).unwrap_err();
        assert!(e.contains(&format!("section layout {}", LAYOUT + 1)) && e.contains("open it with a newer one"), "{e}");
        let e = read::<SchemaSection>(&later).unwrap_err();
        assert!(
            e.contains("open it with a newer one"),
            "reading the section refuses it too, whoever forgets layout_of: {e}"
        );
    }
}
