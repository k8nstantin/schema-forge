// Generated from crates/serve/src/api.rs by `UPDATE_TYPES=1 cargo test -p schema-forge-serve`: never edit by
// hand. The check refuses this file when it differs from what the Rust types say (docs/api.md).

export type Engine = { id: string, name: string, namespace_word: Words, versions: Array<VersionView>, default_version: string, kinds: Array<KindView>, reads?: string, writes: boolean, live?: LiveView, };

export type Words = { one: string, many: string, };

export type VersionView = { id: string, name: string, };

export type KindView = { id: string, name: string, table: boolean, };

export type LiveView = { fields: Array<Field>, };

export type Field = { key: string, label: string, kind: FieldKind, choices: Array<string>, default?: string, help: string, required: boolean, };

export type FieldKind = "text" | "number" | "one_of" | "path" | "secret";

export type WorkspaceInfo = { folder: string, };

export type Listing = { path: string, parent?: string, entries: Array<Entry>, };

export type Entry = { name: string, dir: boolean, size?: number, hidden: boolean, };

export type SchemaSummary = { name: string, engine: string, engine_name: string, version: string, version_name: string, namespace_word: Words, counts: Array<KindCount>, columns: number, links: number, source?: Source, 
/**
 * When it was read, in milliseconds since the Unix epoch.
 */
read_at?: number, adds_up?: boolean, not_understood: number, problems: number, 
/**
 * When the schema's file cannot be read: then only `name` is certain.
 */
error?: string, };

export type KindCount = { kind: string, name: string, count: number, };

export type Source = { "kind": "file", path: string, } | { "kind": "live", connection: string, summary: string, which: Array<string>, };

export type ImportRequest = { path: string, name: string, engine?: string, replace: boolean, };

export type LiveReadRequest = { connection: string, secret?: string, which: Array<string>, name: string, replace: boolean, };

export type ReadResult = { schema: SchemaSummary, report: ReadReport, };

export type ReadReport = { unit: string, read: number, modelled: number, kept: Array<KeptCount>, data: number, machinery: number, not_understood: Array<NotUnderstood>, adds_up: boolean, };

export type KeptCount = { kind: string, count: number, };

export type NotUnderstood = { at: string, start: string, };

export type SchemaView = { summary: SchemaSummary, namespaces: Array<NamespaceView>, objects: Array<ObjectView>, links: Array<LinkView>, shape: Shape, kept: Array<KeptView>, problems: Array<ProblemView>, };

export type NamespaceView = { id: string, name: string, 
/**
 * Its names from the top down, joined with `.`.
 */
path: string, };

export type KeptView = { kind: string, text: string, };

export type ProblemView = { object?: string, message: string, };

export type OptionView = { key: string, value: string, };

export type ObjectView = { id: string, kind: string, kind_name: string, table: boolean, namespace: string, name: string, comment?: string, columns: Array<ColumnView>, keys: Array<KeyView>, indexes: Array<IndexView>, checks: Array<CheckView>, partitioning?: PartitioningView, query?: string, routine?: RoutineView, trigger?: TriggerView, event?: EventView, reads: Array<string>, read_by: Array<string>, triggers: Array<string>, options: Array<OptionView>, };

export type ColumnView = { id: string, name: string, type: string, null: boolean, comment?: string, default?: string, identity: boolean, generated?: GeneratedView, options: Array<OptionView>, };

export type GeneratedView = { expression: string, stored: boolean, };

export type KeyKind = "primary" | "unique" | "identifier";

export type KeyView = { what: KeyKind, name?: string, 
/**
 * Column ids, in order.
 */
columns: Array<string>, };

export type IndexView = { name: string, unique: boolean, method?: string, 
/**
 * Each part as text: a column's name or an expression, with its direction and options.
 */
parts: Array<string>, condition?: string, options: Array<OptionView>, };

export type CheckView = { name?: string, expression: string, options: Array<OptionView>, };

export type PartitioningView = { strategy?: string, 
/**
 * Each field as text: a column's name or an expression, through its transform.
 */
by: Array<string>, partitions: Array<PartitionView>, options: Array<OptionView>, };

export type PartitionView = { name: string, bounds: string, };

export type RoutineView = { parameters: Array<ParameterView>, returns?: string, language?: string, deterministic?: boolean, security?: string, body: string, options: Array<OptionView>, };

export type ParameterView = { name: string, type: string, 
/**
 * `in`, `out` or `in out`.
 */
mode: string, };

export type TriggerView = { 
/**
 * `before`, `after` or `instead of`.
 */
timing: string, 
/**
 * `insert`, `update`, `delete`, `truncate`.
 */
events: Array<string>, 
/**
 * The object it is on.
 */
on: string, condition?: string, body: string, options: Array<OptionView>, };

export type EventView = { schedule: string, enabled: boolean, preserve: boolean, body: string, options: Array<OptionView>, };

export type LinkView = { id: string, name?: string, from: EndsView, to: EndsView, enforced: boolean, on_delete?: string, on_update?: string, options: Array<OptionView>, };

export type EndsView = { object: string, columns: Array<string>, };

export type Shape = { tables: Array<TableShape>, families: Array<Family>, links: Array<ShapeLink>, };

export type TableShape = { table: string, family: string, copy_of?: string, stack?: Stack, };

export type Stack = { series: string, label: string, count: number, };

export type Family = { namespace: string, name: string, tables: number, copies: number, };

export type ShapeLink = { from: string, column: string, to: string, declared: boolean, shared: boolean, };

export type ConnectionView = { name: string, engine: string, engine_name: string, values: { [key in string]: string }, summary: string, tested?: Tested, };

export type Tested = { at: number, outcome: Outcome, };

export type Outcome = "passed" | "warning" | "failed";

export type ConnectionRequest = { engine: string, values: { [key in string]: string }, };

export type TestRequest = { name?: string, engine?: string, values?: { [key in string]: string }, secret?: string, };

export type TestResult = { outcome: Outcome, steps: Array<StepView>, };

export type StepView = { step: StepName, name: string, outcome: StepOutcome, said: string, };

export type StepName = "reach" | "secure" | "sign_in" | "version" | "rights";

export type StepOutcome = "passed" | "warning" | "failed" | "skipped";

export type Done = { done: string, };

export type ApiError = { error: string, };
