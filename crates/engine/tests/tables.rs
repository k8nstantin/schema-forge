//! The tables interface (specs/tasks/SF-94-tables-interface.xml): a schema as the cortex's rows and back, the ids of
//! the parts the model gives none, and the kit's checks of an engine's tables. Under an engine of this file's own
//! that declares two kinds (a table with keys, a view with a query) and no options; the cortex's table files are read
//! from schema/cortex for every table's columns and their types.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use schema_forge_engine::kinds::{ObjectKind, Slot};
use schema_forge_engine::kit::{self, Sample, Samples};
use schema_forge_engine::sections::{
    self, Action, Change, Check, ColumnSection, Deferrable, Direction, Domain, Event, Field, Generated,
    Identity as ColumnIdentity, Index, IndexPart, Kept, Key, LinkSection, Mode, Nulls, ObjectSection, OrderField,
    PartField, Partition, PartitionOf, Partitioning, Routine, SchemaSection, Sequence, Timing, Trigger,
};
use schema_forge_engine::tables::{
    self, File, Identity, Row, Rows, Tables, Value, cortex_rows, cortex_schema, counter_id,
};
use schema_forge_engine::{
    Engine, Imported, Input, Parsed, Read, Report, TypeError, TypeGroup, TypeSpec, Types, Version,
};
use schema_forge_model::{Area, Column, Ends, Id, Link, Namespace, Object, Schema};

// --- the test engine -----------------------------------------------------------------------------------------------

const KINDS: &[ObjectKind] =
    &[ObjectKind::new("table", "Table", &[Slot::Keys]), ObjectKind::new("view", "View", &[Slot::Query])];
const VERSIONS: &[Version] = &[Version::new("1", "Tablet 1")];
const GROUPS: &[TypeGroup] = &[TypeGroup::new("numbers", "Numbers")];
const CATALOG: &[TypeSpec] = &[TypeSpec::new("int", "numbers", "a whole number", "int")];

struct TypesOf;

impl Types for TypesOf {
    fn groups(&self) -> &[TypeGroup] {
        GROUPS
    }
    fn catalog(&self) -> &[TypeSpec] {
        CATALOG
    }
    fn parse(&self, text: &str, _version: &str) -> Result<Parsed, TypeError> {
        if text == "int" { Ok(Parsed::new("int", "int")) } else { Err(TypeError::NotAType(text.to_string())) }
    }
}

/// What a copy of the engine's tables gets wrong, to prove the kit finds it.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Broken {
    Nothing,
    TableOutside,
    RowOfAnother,
    WrongType,
    LosesValue,
}

struct Tablet {
    broken: Broken,
    tables: TabletTables,
    reader: Option<Reader>,
}

impl Tablet {
    fn new() -> Self {
        Self { broken: Broken::Nothing, tables: TabletTables(Broken::Nothing), reader: None }
    }

    fn broken(broken: Broken) -> Self {
        Self { broken, tables: TabletTables(broken), reader: Some(Reader) }
    }
}

impl Engine for Tablet {
    fn id(&self) -> &'static str {
        "tablet"
    }
    fn name(&self) -> &'static str {
        "Tablet"
    }
    fn versions(&self) -> &[Version] {
        VERSIONS
    }
    fn types(&self) -> &dyn Types {
        &TypesOf
    }
    fn kinds(&self) -> &[ObjectKind] {
        KINDS
    }
    fn read(&self) -> Option<&dyn Read> {
        self.reader.as_ref().map(|r| r as &dyn Read)
    }
    fn tables(&self) -> Option<&dyn Tables> {
        (self.broken != Broken::Nothing || self.reader.is_some()).then_some(&self.tables as &dyn Tables)
    }
}

/// Reads any file as the same small schema, one of its tables holding an option `note`.
struct Reader;

impl Read for Reader {
    fn reads(&self) -> &'static str {
        "anything"
    }
    fn recognises(&self, _input: &Input) -> bool {
        true
    }
    fn read(&self, _input: &Input) -> Result<Imported, String> {
        let mut schema = Schema::new("tablet", "1");
        schema.namespaces.push(Namespace::new(id("n_main"), "main"));
        let mut t = Object::new(id("o_items"), "table", id("n_main"), "items");
        t.columns.push(Column::new(id("c_items_id"), "id", "int", false));
        let mut s = ObjectSection::default();
        s.options.insert("note".into(), serde_json::json!("kept"));
        t.engine = sections::write(&s);
        schema.objects.push(t);
        let mut report = Report::new("statements");
        report.read = 1;
        report.modelled = 1;
        Ok(Imported::new(schema, report))
    }
}

struct TabletTables(Broken);

const FILES_OWN: &[File] = &[File {
    name: "engine_tablet.object_notes",
    sql: "CREATE TABLE engine_tablet.object_notes (\n  id    TEXT    NOT NULL PRIMARY KEY,  -- the object\n  note  TEXT,  -- its note\n  weight INTEGER  -- how much it counts\n);\n",
}];
const FILES_OUTSIDE: &[File] =
    &[File { name: "public.object_notes", sql: "CREATE TABLE public.object_notes (\n  id TEXT\n);\n" }];

impl Tables for TabletTables {
    fn card(&self) -> &'static str {
        "id = \"tablet\"\nkind = \"engine\"\nnamespace = \"engine_tablet\"\nversion = 1\nrequires_cortex = 1\n"
    }
    fn files(&self) -> &[File] {
        if self.0 == Broken::TableOutside { FILES_OUTSIDE } else { FILES_OWN }
    }
    fn rules(&self) -> &[File] {
        &[]
    }
    fn rows(&self, schema: &Schema) -> Result<Rows, String> {
        let mut rows = Rows::new();
        for o in &schema.objects {
            let s: ObjectSection = sections::read(&o.engine).map_err(|e| format!("{}: {e}", o.id))?;
            let Some(note) = s.options.get("note").and_then(|v| v.as_str()) else { continue };
            let mut values = BTreeMap::new();
            values.insert("id".to_string(), Value::Text(o.id.to_string()));
            values.insert("note".to_string(), Value::Text(note.to_string()));
            let weight = if self.0 == Broken::WrongType { Value::Text("heavy".into()) } else { Value::Integer(1) };
            values.insert("weight".to_string(), weight);
            let table =
                if self.0 == Broken::RowOfAnother { "engine_tablet.elsewhere" } else { "engine_tablet.object_notes" };
            rows.entry(table.to_string()).or_default().push(Row { table: table.to_string(), values });
        }
        Ok(rows)
    }
    fn read(&self, rows: &Rows, schema: &mut Schema) -> Result<(), String> {
        if self.0 == Broken::LosesValue {
            return Ok(());
        }
        for row in rows.get("engine_tablet.object_notes").into_iter().flatten() {
            let Some(Value::Text(note)) = row.values.get("note") else { continue };
            if let Some(o) = schema.objects.iter_mut().find(|o| o.id.as_str() == row.id()) {
                let mut s: ObjectSection = sections::read(&o.engine)?;
                s.options.insert("note".into(), serde_json::json!(note));
                o.engine = sections::write(&s);
            }
        }
        Ok(())
    }
}

// --- helpers -------------------------------------------------------------------------------------------------------

fn id(s: &str) -> Id {
    Id::try_from(s).expect("an id")
}

fn identity() -> Identity {
    Identity {
        id: "0190b6a0-1234-7abc-8def-0123456789ab".into(),
        name: "shop".into(),
        comment: Some("a test schema".into()),
        created_at: "2026-11-24T00:00:00Z".into(),
    }
}

/// Every cortex table file's columns and their types, from schema/cortex.
fn cortex_files() -> BTreeMap<String, Vec<(String, String)>> {
    const TYPES: [&str; 8] = ["TEXT", "INTEGER", "BIGINT", "NUMERIC", "BOOLEAN", "UUID", "TIMESTAMPTZ", "JSONB"];
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../schema/cortex");
    let mut out = BTreeMap::new();
    for entry in std::fs::read_dir(&dir).expect("schema/cortex") {
        let path = entry.expect("an entry").path();
        let sql = std::fs::read_to_string(&path).unwrap_or_default();
        let Some(start) = sql.find("CREATE TABLE cortex.") else { continue };
        let rest = &sql[start + "CREATE TABLE ".len()..];
        let name = rest.split_whitespace().next().unwrap_or("").to_string();
        let body = &rest[..rest.find("\n);").unwrap_or(rest.len())];
        let columns = body
            .lines()
            .skip(1)
            .filter_map(|l| {
                let mut w = l.split_whitespace();
                let c = w.next()?.trim_matches('"');
                let t = w.next()?.trim_end_matches(',');
                TYPES.contains(&t).then(|| (c.to_string(), t.to_string()))
            })
            .collect();
        out.insert(name, columns);
    }
    out
}

/// A schema with every slot of the layout filled, its section's format included.
fn full() -> Schema {
    let mut schema = Schema::new("tablet", "1");
    let mut main = Namespace::new(id("n_sales"), "sales");
    main.comment = Some("what is sold".into());
    let mut eu = Namespace::new(id("n_sales_eu"), "eu");
    eu.parent = Some(id("n_sales"));
    schema.namespaces = vec![main, eu];
    let mut area = Area::new(id("a_billing"), "billing");
    area.colour = Some("#9500bf".into());
    schema.areas = vec![area, Area::new(id("a_catalog"), "catalog")];

    let mut orders = Object::new(id("o_orders"), "table", id("n_sales"), "orders");
    orders.comment = Some("one row per order".into());
    orders.notes = Some("longer notes".into());
    orders.tags = vec!["pii".into(), "scd2".into()];
    orders.area = Some(id("a_billing"));
    let mut oid = Column::new(id("c_orders_id"), "id", "int", false);
    let mut ident = ColumnIdentity::default();
    ident.always = true;
    ident.start = Some(10);
    ident.increment = Some(5);
    ident.min = Some(1);
    ident.max = Some(1_000_000);
    ident.cache = Some(20);
    ident.cycle = true;
    let mut cs = ColumnSection::default();
    cs.identity = Some(ident);
    oid.engine = sections::write(&cs);
    let mut total = Column::new(id("c_orders_total"), "total", "int", true);
    total.comment = Some("the sum".into());
    let mut cs = ColumnSection::default();
    cs.default = Some("0".into());
    total.engine = sections::write(&cs);
    let mut doubled = Column::new(id("c_orders_doubled"), "doubled", "int", true);
    let mut g = Generated::default();
    g.expression = "total * 2".into();
    g.stored = true;
    let mut cs = ColumnSection::default();
    cs.generated = Some(g);
    doubled.engine = sections::write(&cs);
    let customer = Column::new(id("c_orders_customer"), "customer", "int", false);
    orders.columns = vec![oid, total, doubled, customer];
    let mut s = ObjectSection::default();
    let mut pk = Key::default();
    pk.name = Some("orders_pkey".into());
    pk.columns = vec![id("c_orders_id")];
    s.keys.primary = Some(pk);
    let mut uk = Key::default();
    uk.columns = vec![id("c_orders_customer"), id("c_orders_total")];
    s.keys.unique = vec![uk];
    s.keys.identifier = vec![id("c_orders_id")];
    let mut check = Check::default();
    check.name = Some("positive".into());
    check.expression = "total >= 0".into();
    s.checks = vec![check];
    let mut index = Index::default();
    index.name = "orders_total".into();
    index.unique = true;
    index.method = Some("btree".into());
    let mut p1 = IndexPart::default();
    p1.column = Some(id("c_orders_total"));
    p1.direction = Some(Direction::Desc);
    p1.nulls = Some(Nulls::Last);
    let mut p2 = IndexPart::default();
    p2.expression = Some("lower(x)".into());
    index.parts = vec![p1, p2];
    index.include = vec![id("c_orders_customer")];
    index.condition = Some("total > 0".into());
    s.indexes = vec![index];
    let mut partitioning = Partitioning::default();
    partitioning.strategy = Some("range".into());
    let mut by = PartField::default();
    by.column = Some(id("c_orders_id"));
    by.transform = Some("bucket[16]".into());
    let mut by2 = PartField::default();
    by2.expression = Some("year(placed)".into());
    partitioning.by = vec![by, by2];
    let mut part = Partition::default();
    part.name = "p2025".into();
    part.bounds = "VALUES LESS THAN (2026)".into();
    partitioning.partitions = vec![part];
    s.partitioning = Some(partitioning);
    let mut of = OrderField::new(id("c_orders_total"));
    of.transform = Some("day".into());
    of.direction = Some(Direction::Asc);
    of.nulls = Some(Nulls::First);
    s.order = vec![of];
    orders.engine = sections::write(&s);

    let mut part2024 = Object::new(id("o_orders_2024"), "table", id("n_sales_eu"), "orders_2024");
    let mut s = ObjectSection::default();
    s.partition_of = Some(PartitionOf::new(id("o_orders"), "FOR VALUES FROM (2024) TO (2025)"));
    part2024.engine = sections::write(&s);

    let mut current = Object::new(id("o_current"), "view", id("n_sales"), "current");
    current.reads = vec![id("o_orders"), id("o_orders_2024")];
    let mut s = ObjectSection::default();
    s.query = Some("SELECT * FROM orders".into());
    current.engine = sections::write(&s);

    let mut seq = Object::new(id("o_seq"), "table", id("n_sales"), "seq");
    let mut s = ObjectSection::default();
    let mut q = Sequence::default();
    q.data_type = Some("bigint".into());
    q.start = Some(1);
    q.increment = Some(2);
    q.min = Some(1);
    q.max = Some(99);
    q.cache = Some(5);
    q.cycle = true;
    q.owned_by = Some(id("c_orders_id"));
    s.sequence = Some(q);
    seq.engine = sections::write(&s);

    let mut status = Object::new(id("o_status"), "table", id("n_sales"), "status");
    let mut s = ObjectSection::default();
    s.values = vec!["new".into(), "paid".into()];
    status.engine = sections::write(&s);

    let mut money = Object::new(id("o_money"), "table", id("n_sales"), "money");
    let mut s = ObjectSection::default();
    let mut d = Domain::default();
    d.base = "numeric(18,2)".into();
    d.default = Some("0".into());
    d.null = false;
    s.domain = Some(d);
    let mut check = Check::default();
    check.expression = "VALUE >= 0".into();
    s.checks = vec![check];
    money.engine = sections::write(&s);

    let mut address = Object::new(id("o_address"), "table", id("n_sales"), "address");
    let mut s = ObjectSection::default();
    let mut f = Field::default();
    f.name = "street".into();
    f.data_type = "text".into();
    f.comment = Some("the street".into());
    s.fields = vec![f];
    address.engine = sections::write(&s);

    let mut close = Object::new(id("o_close"), "table", id("n_sales"), "close");
    let mut s = ObjectSection::default();
    let mut r = Routine::default();
    let mut a = sections::Parameter::default();
    a.name = "p_id".into();
    a.data_type = "int".into();
    a.mode = Some(Mode::InOut);
    a.default = Some("1".into());
    r.parameters = vec![a];
    r.returns = Some("int".into());
    r.language = Some("sql".into());
    r.deterministic = Some(false);
    r.security = Some("invoker".into());
    r.body = "BEGIN\n  RETURN 1;\nEND".into();
    s.routine = Some(r);
    close.engine = sections::write(&s);

    let mut touch = Object::new(id("o_touch"), "table", id("n_sales"), "touch");
    let mut s = ObjectSection::default();
    let mut t = Trigger::new(Timing::InsteadOf, vec![Change::Insert, Change::Update], id("o_orders"), "SET x = 1");
    t.condition = Some("NEW.total > 0".into());
    s.trigger = Some(t);
    touch.engine = sections::write(&s);

    let mut nightly = Object::new(id("o_nightly"), "table", id("n_sales"), "nightly");
    let mut s = ObjectSection::default();
    let mut e = Event::default();
    e.schedule = "EVERY 1 DAY".into();
    e.preserve = true;
    e.enabled = false;
    e.body = "DELETE FROM x".into();
    s.event = Some(e);
    nightly.engine = sections::write(&s);

    let mut customers = Object::new(id("o_customers"), "table", id("n_sales"), "customers");
    customers.columns = vec![Column::new(id("c_customers_id"), "id", "int", false)];

    schema.objects = vec![orders, part2024, current, seq, status, money, address, close, touch, nightly, customers];

    let mut link = Link::new(
        id("l_orders_customer"),
        Ends::new(id("o_orders"), vec![id("c_orders_customer")]),
        Ends::new(id("o_customers"), vec![id("c_customers_id")]),
    );
    link.name = Some("fk_customer".into());
    let mut ls = LinkSection::default();
    ls.enforced = false;
    ls.on_delete = Some(Action::Cascade);
    ls.on_update = Some(Action::SetNull);
    ls.match_kind = Some("full".into());
    let mut df = Deferrable::default();
    df.initially_deferred = true;
    ls.deferrable = Some(df);
    link.engine = sections::write(&ls);
    schema.links = vec![link];

    let mut ss = SchemaSection::default();
    ss.format = 3;
    let mut k1 = Kept::default();
    k1.kind = "grant".into();
    k1.text = "GRANT SELECT ON x TO y".into();
    let mut k2 = Kept::default();
    k2.kind = "other".into();
    k2.text = "SET a = 1".into();
    k2.after = Some(id("n_sales"));
    let mut k3 = Kept::default();
    k3.kind = "other".into();
    k3.text = "ANALYZE orders".into();
    k3.after = Some(id("o_orders"));
    ss.kept = vec![k1, k2, k3];
    ss.requires = vec!["postgis".into(), "pgvector".into()];
    schema.engine_section = sections::write(&ss);
    schema
}

fn rows_of<'a>(rows: &'a Rows, table: &str) -> &'a [Row] {
    rows.get(&format!("cortex.{table}")).map_or(&[], Vec::as_slice)
}

fn value<'a>(row: &'a Row, column: &str) -> &'a Value {
    row.values.get(column).expect("the column")
}

// --- step 1 --------------------------------------------------------------------------------------------------------

#[test]
fn every_value_cortex_rows_writes_is_the_variant_of_its_column_s_type_in_its_table_file() {
    let files = cortex_files();
    let rows = cortex_rows(&full(), &Tablet::new(), &identity()).expect("rows");
    for (table, rows) in &rows {
        let columns = &files[table];
        for row in rows {
            for (column, v) in &row.values {
                let (_, ty) = columns.iter().find(|(c, _)| c == column).expect("a column of the file");
                assert!(v.is_of(ty), "{table} {}: {column} is {v:?}, not {ty}", row.id());
            }
        }
    }
}

#[test]
fn a_position_is_a_decimal_a_flag_a_boolean_an_absent_optional_value_null() {
    let rows = cortex_rows(&full(), &Tablet::new(), &identity()).expect("rows");
    let objects = rows_of(&rows, "objects");
    assert_eq!(value(&objects[1], "position"), &Value::Numeric("2".into()));
    let orders = &objects[0];
    assert_eq!(value(orders, "comment"), &Value::Text("one row per order".into()));
    let customers = objects.iter().find(|r| r.id() == "o_customers").expect("customers");
    assert_eq!(value(customers, "area"), &Value::Null);
    let columns = rows_of(&rows, "columns");
    assert_eq!(value(&columns[0], "nullable"), &Value::Bool(false));
    assert_eq!(value(&columns[0], "generated_stored"), &Value::Null);
}

// --- step 2 --------------------------------------------------------------------------------------------------------

#[test]
fn every_id_function_gives_the_id_the_cortex_table_files_require_in_their_id_checks_numbering_from_1_in_the_model_s_order()
 {
    // (table, the parent column, the word between the parent and the number), as each file's id CHECK says
    let numbered = [
        ("table_keys", "object", ".key"),
        ("table_key_columns", "key", "."),
        ("check_constraints", "object", ".check"),
        ("indexes", "object", ".index"),
        ("index_parts", "index", "."),
        ("index_includes", "index", ".include"),
        ("partition_fields", "partitioning", ".by"),
        ("partitions", "partitioning", ".partition"),
        ("sort_fields", "object", ".order"),
        ("enum_values", "object", ".value"),
        ("composite_type_fields", "object", ".field"),
        ("routine_parameters", "routine", ".param"),
        ("trigger_events", "trigger", ".on"),
        ("object_tags", "object", ".tag"),
        ("object_reads", "object", ".read"),
        ("relationship_columns", "relationship", "."),
    ];
    let rows = cortex_rows(&full(), &Tablet::new(), &identity()).expect("rows");
    for (table, parent, word) in numbered {
        let mut seen: BTreeMap<String, usize> = BTreeMap::new();
        assert!(!rows_of(&rows, table).is_empty(), "{table} has rows to check");
        for row in rows_of(&rows, table) {
            let Value::Text(p) = value(row, parent) else { panic!("{table}: {parent} is text") };
            let n = seen.entry(p.clone()).or_insert(0);
            *n += 1;
            assert_eq!(row.id(), format!("{p}{word}{n}"), "{table}: numbered from 1 in the model's order");
        }
    }
    for (i, row) in rows_of(&rows, "verbatim_statements").iter().enumerate() {
        assert_eq!(row.id(), tables::verbatim_statement_id(i + 1));
    }
    assert_eq!(tables::table_key_id("o_orders", 1), "o_orders.key1");
    assert_eq!(tables::index_include_id("o_orders.index1", 2), "o_orders.index1.include2");
    assert_eq!(tables::trigger_event_id("o_touch", 1), "o_touch.on1");
}

#[test]
fn a_counter_row_is_written_for_every_counter_id_used_holding_the_greatest_number_given_under_it() {
    let rows = cortex_rows(&full(), &Tablet::new(), &identity()).expect("rows");
    let mut want: BTreeMap<String, i64> = BTreeMap::new();
    for (table, rs) in &rows {
        if matches!(
            table.as_str(),
            "cortex.table_keys"
                | "cortex.table_key_columns"
                | "cortex.check_constraints"
                | "cortex.indexes"
                | "cortex.index_parts"
                | "cortex.index_includes"
                | "cortex.partition_fields"
                | "cortex.partitions"
                | "cortex.sort_fields"
                | "cortex.enum_values"
                | "cortex.composite_type_fields"
                | "cortex.routine_parameters"
                | "cortex.trigger_events"
                | "cortex.object_tags"
                | "cortex.object_reads"
                | "cortex.relationship_columns"
                | "cortex.verbatim_statements"
        ) {
            for r in rs {
                let n: i64 = r.id()[counter_id(r.id()).len()..].parse().expect("a number");
                let e = want.entry(counter_id(r.id())).or_insert(0);
                *e = (*e).max(n);
            }
        }
    }
    let got: BTreeMap<String, i64> = rows_of(&rows, "id_counters")
        .iter()
        .map(|r| {
            (
                r.id().to_string(),
                match value(r, "last") {
                    Value::Integer(n) => *n,
                    _ => 0,
                },
            )
        })
        .collect();
    assert_eq!(got, want);
    assert_eq!(got["o_orders.key"], 3, "primary, unique, identifier");
}

// --- step 3 --------------------------------------------------------------------------------------------------------

#[test]
fn every_row_cortex_rows_writes_is_of_a_cortex_table_and_names_every_column_of_that_table_s_file_and_no_other() {
    let files = cortex_files();
    let rows = cortex_rows(&full(), &Tablet::new(), &identity()).expect("rows");
    for (table, rs) in &rows {
        let want: BTreeSet<&str> = files.get(table).expect("a cortex table").iter().map(|(c, _)| c.as_str()).collect();
        for r in rs {
            assert_eq!(&r.table, table);
            let got: BTreeSet<&str> = r.values.keys().map(String::as_str).collect();
            assert_eq!(got, want, "{table} {}", r.id());
        }
    }
    for kept in ["cortex.schema_migrations", "cortex.turns", "cortex.operations"] {
        assert!(!rows.contains_key(kept), "{kept} is the store's");
    }
}

#[test]
fn object_kinds_and_their_parts_are_written_from_the_engine_s_declaration_one_part_row_for_each_slot_of_each_kind() {
    let rows = cortex_rows(&full(), &Tablet::new(), &identity()).expect("rows");
    let kinds: Vec<&str> = rows_of(&rows, "object_kinds").iter().map(Row::id).collect();
    assert_eq!(kinds, ["table", "view"]);
    assert_eq!(value(&rows_of(&rows, "object_kinds")[1], "position"), &Value::Numeric("2".into()));
    let parts: Vec<(&str, &Value)> =
        rows_of(&rows, "object_kind_parts").iter().map(|r| (r.id(), value(r, "slot"))).collect();
    assert_eq!(parts, [("table.keys", &Value::Text("keys".into())), ("view.query", &Value::Text("query".into()))]);
}

#[test]
fn table_keys_are_written_primary_first_then_unique_then_identifier_each_with_its_columns_in_order() {
    let rows = cortex_rows(&full(), &Tablet::new(), &identity()).expect("rows");
    let keys: Vec<(&str, &Value)> = rows_of(&rows, "table_keys").iter().map(|r| (r.id(), value(r, "what"))).collect();
    assert_eq!(
        keys,
        [
            ("o_orders.key1", &Value::Text("primary".into())),
            ("o_orders.key2", &Value::Text("unique".into())),
            ("o_orders.key3", &Value::Text("identifier".into())),
        ]
    );
    let unique: Vec<&Value> = rows_of(&rows, "table_key_columns")
        .iter()
        .filter(|r| value(r, "key") == &Value::Text("o_orders.key2".into()))
        .map(|r| value(r, "column"))
        .collect();
    assert_eq!(unique, [&Value::Text("c_orders_customer".into()), &Value::Text("c_orders_total".into())]);
}

#[test]
fn a_section_that_does_not_follow_the_layout_is_an_error_naming_its_part() {
    let mut schema = full();
    schema.objects[2].engine.insert("storage_engine".into(), serde_json::json!("heap"));
    let e = cortex_rows(&schema, &Tablet::new(), &identity()).unwrap_err();
    assert!(e.starts_with("o_current: ") && e.contains("storage_engine"), "{e}");
}

#[test]
fn the_identity_row_is_written_from_the_identity_given_and_a_verbatim_statement_after_a_namespace_or_an_object_refers_to_it_by_the_column_of_its_kind()
 {
    let rows = cortex_rows(&full(), &Tablet::new(), &identity()).expect("rows");
    let i = &rows_of(&rows, "schema_identity")[0];
    assert_eq!(value(i, "id"), &Value::Uuid(identity().id));
    assert_eq!(value(i, "name"), &Value::Text("shop".into()));
    assert_eq!(value(i, "engine"), &Value::Text("tablet".into()));
    assert_eq!(value(i, "section_format"), &Value::Integer(3));
    assert_eq!(value(i, "created_at"), &Value::Timestamp("2026-11-24T00:00:00Z".into()));
    assert_eq!(value(i, "one"), &Value::Bool(true));
    let kept = rows_of(&rows, "verbatim_statements");
    assert_eq!((value(&kept[0], "after_namespace"), value(&kept[0], "after_object")), (&Value::Null, &Value::Null));
    assert_eq!(value(&kept[1], "after_namespace"), &Value::Text("n_sales".into()));
    assert_eq!(value(&kept[2], "after_object"), &Value::Text("o_orders".into()));
    let mut schema = full();
    let mut ss: SchemaSection = sections::read(&schema.engine_section).expect("layout");
    ss.kept[0].after = Some(id("c_orders_id"));
    schema.engine_section = sections::write(&ss);
    let e = cortex_rows(&schema, &Tablet::new(), &identity()).unwrap_err();
    assert_eq!(e, "statement 1: it follows c_orders_id, which is neither a namespace nor an object");
}

// --- step 4 --------------------------------------------------------------------------------------------------------

#[test]
fn a_schema_with_every_slot_of_the_layout_filled_its_section_s_format_included_is_written_by_cortex_rows_and_read_back_by_cortex_schema_as_the_same_schema()
 {
    let schema = full();
    let rows = cortex_rows(&schema, &Tablet::new(), &identity()).expect("rows");
    let back = cortex_schema(&rows, &Tablet::new()).expect("the schema back");
    assert_eq!(back.to_json(), schema.to_json());
    assert_eq!(back, schema);
}

#[test]
fn every_part_comes_back_in_the_order_of_its_position_compared_as_a_decimal_whatever_order_the_rows_are_given_in() {
    let schema = full();
    let mut rows = cortex_rows(&schema, &Tablet::new(), &identity()).expect("rows");
    for rs in rows.values_mut() {
        rs.reverse();
    }
    // positions compared as decimals: 10 becomes the midpoint 9.5, which text would sort after 11 and a decimal before it
    let objects = rows.get_mut("cortex.objects").expect("objects");
    for r in objects.iter_mut() {
        if let Some(Value::Numeric(p)) = r.values.get_mut("position")
            && p == "10"
        {
            *p = "9.5".into();
        }
    }
    let back = cortex_schema(&rows, &Tablet::new()).expect("the schema back");
    assert_eq!(back, schema);
}

#[test]
fn a_row_that_refers_to_a_part_no_row_holds_is_an_error_naming_the_table_the_row_and_the_id() {
    let mut rows = cortex_rows(&full(), &Tablet::new(), &identity()).expect("rows");
    let columns = rows.get_mut("cortex.columns").expect("columns");
    columns[0].values.insert("object".into(), Value::Text("o_gone".into()));
    let e = cortex_schema(&rows, &Tablet::new()).unwrap_err();
    assert_eq!(e, "cortex.columns c_orders_id: refers to o_gone, which no row holds");
}

// --- step 6 --------------------------------------------------------------------------------------------------------

#[test]
fn the_kit_finds_an_engine_table_outside_its_namespace_a_row_of_a_table_the_engine_does_not_hold_a_value_of_the_wrong_type_and_a_round_trip_that_loses_a_value()
 {
    let dir = std::env::temp_dir().join(format!("schema-forge-tables-kit-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a folder");
    let sample = dir.join("sample.txt");
    std::fs::write(&sample, "anything\n").expect("a sample");
    let files = [Sample::read_only(&sample)];
    let found = |broken: Broken| kit::check(&Tablet::broken(broken), &Samples::new(&files, &[]));
    let has = |found: &[String], needle: &str| found.iter().any(|f| f.contains(needle));

    let clean = found(Broken::Nothing);
    let tables_findings = ["is not in tablet's namespace", "rows() writes", "is not INTEGER", "do not give back"];
    assert!(!clean.iter().any(|f| tables_findings.iter().any(|t| f.contains(t))), "{clean:#?}");
    let f = found(Broken::TableOutside);
    assert!(has(&f, "table public.object_notes is not in tablet's namespace engine_tablet"), "{f:#?}");
    let f = found(Broken::RowOfAnother);
    assert!(has(&f, "rows() writes engine_tablet.elsewhere, which is not one of its tables"), "{f:#?}");
    let f = found(Broken::WrongType);
    assert!(has(&f, "engine_tablet.object_notes o_items: weight is not INTEGER"), "{f:#?}");
    let f = found(Broken::LosesValue);
    assert!(has(&f, "its tables do not give back the schema read: o_items"), "{f:#?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_link_whose_ends_hold_different_numbers_of_columns_is_an_error_naming_the_link_and_both_counts() {
    let mut schema = full();
    schema.links[0].to.columns.push(id("c_customers_id"));
    let e = cortex_rows(&schema, &Tablet::new(), &identity()).unwrap_err();
    assert_eq!(e, "l_orders_customer: its ends hold 1 and 2 columns");
}

#[test]
fn a_value_cortex_rows_never_writes_a_word_outside_its_list_or_nothing_in_a_required_column_is_an_error_naming_the_table_the_row_and_the_column()
 {
    let rows = cortex_rows(&full(), &Tablet::new(), &identity()).expect("rows");
    let set = |table: &str, row: &str, column: &str, v: Value| {
        let mut rows = rows.clone();
        let r = rows.get_mut(table).expect("the table").iter_mut().find(|r| r.id() == row).expect("the row");
        r.values.insert(column.into(), v);
        cortex_schema(&rows, &Tablet::new()).unwrap_err()
    };
    assert_eq!(
        set("cortex.triggers", "o_touch", "timing", Value::Text("during".into())),
        "cortex.triggers o_touch: timing is during, which cortex_rows never writes"
    );
    assert_eq!(
        set("cortex.objects", "o_orders", "name", Value::Null),
        "cortex.objects o_orders: name is nothing, which cortex_rows never writes"
    );
    assert_eq!(
        set("cortex.columns", "c_orders_id", "nullable", Value::Text("yes".into())),
        "cortex.columns c_orders_id: nullable is yes, which cortex_rows never writes"
    );
    assert_eq!(
        set("cortex.relationships", "l_orders_customer", "on_delete", Value::Text("explode".into())),
        "cortex.relationships l_orders_customer: on_delete is explode, which cortex_rows never writes"
    );
}

/// A schema of `n` tables of 15 columns, each with a primary key and an index.
fn tables_of(n: usize) -> Schema {
    let mut s = Schema::new("tablet", "1");
    s.namespaces.push(Namespace::new(id("n_main"), "main"));
    for i in 0..n {
        let mut o = Object::new(id(&format!("o_t{i}")), "table", id("n_main"), format!("t{i}"));
        for c in 0..15 {
            o.columns.push(Column::new(id(&format!("c_t{i}_{c}")), format!("c{c}"), "int", true));
        }
        let mut sec = ObjectSection::default();
        let mut k = Key::default();
        k.columns = vec![id(&format!("c_t{i}_0"))];
        sec.keys.primary = Some(k);
        let mut x = Index::default();
        x.name = format!("t{i}_c1");
        let mut p = IndexPart::default();
        p.column = Some(id(&format!("c_t{i}_1")));
        x.parts = vec![p];
        sec.indexes = vec![x];
        o.engine = sections::write(&sec);
        s.objects.push(o);
    }
    s
}

/// The fastest of three reads back of `schema`'s rows.
fn read_back_time(schema: &Schema) -> std::time::Duration {
    let rows = cortex_rows(schema, &Tablet::new(), &identity()).expect("rows");
    (0..3)
        .map(|_| {
            let t = std::time::Instant::now();
            let back = cortex_schema(&rows, &Tablet::new()).expect("back");
            let d = t.elapsed();
            assert_eq!(back.objects.len(), schema.objects.len());
            d
        })
        .min()
        .expect("three reads")
}

#[test]
fn reading_back_twice_as_many_tables_takes_at_most_three_times_as_long() {
    let (small, large) = (tables_of(500), tables_of(1000));
    let (a, b) = (read_back_time(&small), read_back_time(&large));
    assert!(b <= a * 3, "500 tables {a:?}, 1000 tables {b:?}: the read back grows faster than its rows");
}
