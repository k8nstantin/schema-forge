//! The API's types, exactly as docs/api.md lists them: what the server sends and what it takes. The canvas's
//! TypeScript (`canvas/src/api/types.ts`) is generated from these, so the two cannot drift: `cargo test` refuses a
//! generated file that is stale (tests/contract.rs), and `UPDATE_TYPES=1 cargo test -p schema-forge-serve` writes it.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use ts_rs::TS;

/// An engine, as it declares itself.
#[derive(Debug, Clone, Serialize, TS)]
pub struct Engine {
    pub id: String,
    pub name: String,
    pub namespace_word: Words,
    pub versions: Vec<VersionView>,
    pub default_version: String,
    pub kinds: Vec<KindView>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reads: Option<String>,
    pub writes: bool,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub live: Option<LiveView>,
}

/// A word, one and many.
#[derive(Debug, Clone, Default, Serialize, TS)]
pub struct Words {
    pub one: String,
    pub many: String,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct VersionView {
    pub id: String,
    pub name: String,
}

/// A kind of object; `table` when the perspectives draw it as a table (a kind that holds keys).
#[derive(Debug, Clone, Serialize, TS)]
pub struct KindView {
    pub id: String,
    pub name: String,
    pub table: bool,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct LiveView {
    pub fields: Vec<Field>,
}

/// A connection field, as the engine declares it.
#[derive(Debug, Clone, Serialize, TS)]
pub struct Field {
    pub key: String,
    pub label: String,
    pub kind: FieldKind,
    pub choices: Vec<String>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<String>,
    pub help: String,
    pub required: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum FieldKind {
    Text,
    Number,
    OneOf,
    Path,
    Secret,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct WorkspaceInfo {
    pub folder: String,
}

/// A folder on this machine.
#[derive(Debug, Clone, Serialize, TS)]
pub struct Listing {
    pub path: String,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    pub entries: Vec<Entry>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct Entry {
    pub name: String,
    pub dir: bool,
    #[ts(optional, type = "number")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    pub hidden: bool,
}

/// A schema of the workspace, in a line or two.
#[derive(Debug, Clone, Default, Serialize, TS)]
pub struct SchemaSummary {
    pub name: String,
    pub engine: String,
    pub engine_name: String,
    pub version: String,
    pub version_name: String,
    pub namespace_word: Words,
    pub counts: Vec<KindCount>,
    #[ts(type = "number")]
    pub columns: u64,
    #[ts(type = "number")]
    pub links: u64,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    /// When it was read, in milliseconds since the Unix epoch.
    #[ts(optional, type = "number")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub read_at: Option<u64>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub adds_up: Option<bool>,
    #[ts(type = "number")]
    pub not_understood: u64,
    #[ts(type = "number")]
    pub problems: u64,
    /// When the schema's file cannot be read: then only `name` is certain.
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct KindCount {
    pub kind: String,
    pub name: String,
    #[ts(type = "number")]
    pub count: u64,
}

/// Where a schema came from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Source {
    File { path: String },
    Live { connection: String, summary: String, which: Vec<String> },
}

#[derive(Debug, Clone, Deserialize, TS)]
pub struct ImportRequest {
    pub path: String,
    pub name: String,
    #[ts(optional)]
    #[serde(default)]
    pub engine: Option<String>,
    #[serde(default)]
    pub replace: bool,
}

#[derive(Debug, Clone, Deserialize, TS)]
pub struct LiveReadRequest {
    pub connection: String,
    #[ts(optional)]
    #[serde(default)]
    pub secret: Option<String>,
    #[serde(default)]
    pub which: Vec<String>,
    pub name: String,
    #[serde(default)]
    pub replace: bool,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct ReadResult {
    pub schema: SchemaSummary,
    pub report: ReadReport,
}

/// What a read did with everything it read: `read = modelled + kept + data + machinery`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, TS)]
pub struct ReadReport {
    pub unit: String,
    #[ts(type = "number")]
    pub read: u64,
    #[ts(type = "number")]
    pub modelled: u64,
    pub kept: Vec<KeptCount>,
    #[ts(type = "number")]
    pub data: u64,
    #[ts(type = "number")]
    pub machinery: u64,
    pub not_understood: Vec<NotUnderstood>,
    pub adds_up: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, TS)]
pub struct KeptCount {
    pub kind: String,
    #[ts(type = "number")]
    pub count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, TS)]
pub struct NotUnderstood {
    pub at: String,
    pub start: String,
}

/// A schema, as the perspectives show it.
#[derive(Debug, Clone, Serialize, TS)]
pub struct SchemaView {
    pub summary: SchemaSummary,
    pub namespaces: Vec<NamespaceView>,
    pub objects: Vec<ObjectView>,
    pub links: Vec<LinkView>,
    pub shape: Shape,
    pub kept: Vec<KeptView>,
    pub problems: Vec<ProblemView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct NamespaceView {
    pub id: String,
    pub name: String,
    /// Its names from the top down, joined with `.`.
    pub path: String,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct KeptView {
    pub kind: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct ProblemView {
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub object: Option<String>,
    pub message: String,
}

/// What belongs to one engine alone, as text: shown as it is, never read by name.
#[derive(Debug, Clone, Serialize, TS)]
pub struct OptionView {
    pub key: String,
    pub value: String,
}

/// An object, read through the shared section layout.
#[derive(Debug, Clone, Default, Serialize, TS)]
pub struct ObjectView {
    pub id: String,
    pub kind: String,
    pub kind_name: String,
    pub table: bool,
    pub namespace: String,
    pub name: String,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    pub columns: Vec<ColumnView>,
    pub keys: Vec<KeyView>,
    pub indexes: Vec<IndexView>,
    pub checks: Vec<CheckView>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub partitioning: Option<PartitioningView>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub routine: Option<RoutineView>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trigger: Option<TriggerView>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event: Option<EventView>,
    pub reads: Vec<String>,
    pub read_by: Vec<String>,
    pub triggers: Vec<String>,
    pub options: Vec<OptionView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct ColumnView {
    pub id: String,
    pub name: String,
    #[serde(rename = "type")]
    #[ts(rename = "type")]
    pub data_type: String,
    pub null: bool,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<String>,
    pub identity: bool,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generated: Option<GeneratedView>,
    pub options: Vec<OptionView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct GeneratedView {
    pub expression: String,
    pub stored: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum KeyKind {
    Primary,
    Unique,
    Identifier,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct KeyView {
    pub what: KeyKind,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Column ids, in order.
    pub columns: Vec<String>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct IndexView {
    pub name: String,
    pub unique: bool,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    /// Each part as text: a column's name or an expression, with its direction and options.
    pub parts: Vec<String>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
    pub options: Vec<OptionView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct CheckView {
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub expression: String,
    pub options: Vec<OptionView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct PartitioningView {
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub strategy: Option<String>,
    /// Each field as text: a column's name or an expression, through its transform.
    pub by: Vec<String>,
    pub partitions: Vec<PartitionView>,
    pub options: Vec<OptionView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct PartitionView {
    pub name: String,
    pub bounds: String,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct RoutineView {
    pub parameters: Vec<ParameterView>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub returns: Option<String>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deterministic: Option<bool>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub security: Option<String>,
    pub body: String,
    pub options: Vec<OptionView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct ParameterView {
    pub name: String,
    #[serde(rename = "type")]
    #[ts(rename = "type")]
    pub data_type: String,
    /// `in`, `out` or `in out`.
    pub mode: String,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct TriggerView {
    /// `before`, `after` or `instead of`.
    pub timing: String,
    /// `insert`, `update`, `delete`, `truncate`.
    pub events: Vec<String>,
    /// The object it is on.
    pub on: String,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
    pub body: String,
    pub options: Vec<OptionView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct EventView {
    pub schedule: String,
    pub enabled: bool,
    pub preserve: bool,
    pub body: String,
    pub options: Vec<OptionView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct LinkView {
    pub id: String,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub from: EndsView,
    pub to: EndsView,
    pub enforced: bool,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_delete: Option<String>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_update: Option<String>,
    pub options: Vec<OptionView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct EndsView {
    pub object: String,
    pub columns: Vec<String>,
}

/// Families, stacked copies and links, as the perspectives group and draw tables.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct Shape {
    pub tables: Vec<TableShape>,
    pub families: Vec<Family>,
    pub links: Vec<ShapeLink>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct TableShape {
    pub table: String,
    pub family: String,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub copy_of: Option<String>,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stack: Option<Stack>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct Stack {
    pub series: String,
    pub label: String,
    #[ts(type = "number")]
    pub count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct Family {
    pub namespace: String,
    pub name: String,
    #[ts(type = "number")]
    pub tables: u64,
    #[ts(type = "number")]
    pub copies: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct ShapeLink {
    pub from: String,
    pub column: String,
    pub to: String,
    pub declared: bool,
    pub shared: bool,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct ConnectionView {
    pub name: String,
    pub engine: String,
    pub engine_name: String,
    pub values: BTreeMap<String, String>,
    pub summary: String,
    #[ts(optional)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tested: Option<Tested>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, TS)]
pub struct Tested {
    #[ts(type = "number")]
    pub at: u64,
    pub outcome: Outcome,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Passed,
    Warning,
    Failed,
}

#[derive(Debug, Clone, Deserialize, TS)]
pub struct ConnectionRequest {
    pub engine: String,
    pub values: BTreeMap<String, String>,
}

/// A saved connection by `name`, or the `engine` and `values` of one not saved.
#[derive(Debug, Clone, Deserialize, TS)]
pub struct TestRequest {
    #[ts(optional)]
    #[serde(default)]
    pub name: Option<String>,
    #[ts(optional)]
    #[serde(default)]
    pub engine: Option<String>,
    #[ts(optional)]
    #[serde(default)]
    pub values: Option<BTreeMap<String, String>>,
    #[ts(optional)]
    #[serde(default)]
    pub secret: Option<String>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct TestResult {
    pub outcome: Outcome,
    pub steps: Vec<StepView>,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct StepView {
    pub step: StepName,
    pub name: String,
    pub outcome: StepOutcome,
    pub said: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum StepName {
    Reach,
    Secure,
    SignIn,
    Version,
    Rights,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum StepOutcome {
    Passed,
    Warning,
    Failed,
    Skipped,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct Done {
    pub done: String,
}

#[derive(Debug, Clone, Serialize, TS)]
pub struct ApiError {
    pub error: String,
}

/// The TypeScript of every type above, in this order: what `canvas/src/api/types.ts` holds.
#[must_use]
pub fn typescript() -> String {
    let cfg = ts_rs::Config::default();
    let mut out = String::from(
        "// Generated from crates/serve/src/api.rs by `UPDATE_TYPES=1 cargo test -p schema-forge-serve`: never edit by\n\
         // hand. The check refuses this file when it differs from what the Rust types say (docs/api.md).\n",
    );
    macro_rules! each {
        ($($t:ty),* $(,)?) => {
            $(
                out.push_str("\nexport ");
                out.push_str(&<$t as TS>::decl(&cfg));
                out.push('\n');
            )*
        };
    }
    each!(
        Engine,
        Words,
        VersionView,
        KindView,
        LiveView,
        Field,
        FieldKind,
        WorkspaceInfo,
        Listing,
        Entry,
        SchemaSummary,
        KindCount,
        Source,
        ImportRequest,
        LiveReadRequest,
        ReadResult,
        ReadReport,
        KeptCount,
        NotUnderstood,
        SchemaView,
        NamespaceView,
        KeptView,
        ProblemView,
        OptionView,
        ObjectView,
        ColumnView,
        GeneratedView,
        KeyKind,
        KeyView,
        IndexView,
        CheckView,
        PartitioningView,
        PartitionView,
        RoutineView,
        ParameterView,
        TriggerView,
        EventView,
        LinkView,
        EndsView,
        Shape,
        TableShape,
        Stack,
        Family,
        ShapeLink,
        ConnectionView,
        Tested,
        Outcome,
        ConnectionRequest,
        TestRequest,
        TestResult,
        StepView,
        StepName,
        StepOutcome,
        Done,
        ApiError,
    );
    out
}
