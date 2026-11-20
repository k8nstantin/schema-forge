//! Reading and writing Iceberg Spark SQL (tests/fixtures/iceberg, laid out <catalog>/<namespace>/<table>.sql).

use schema_forge_core::{Direction, Nulls, check};
use schema_forge_dialects::iceberg::{generate, import, import_folder};

fn read() -> schema_forge_dialects::Imported {
    import_folder(&std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/iceberg")).expect("read")
}

#[test]
fn the_folder_reads_whole_and_round_trips() {
    let imported = read();
    let r = &imported.report;
    assert!(r.adds_up() && r.not_understood.is_empty(), "{r}");
    assert_eq!((r.statements, r.modelled), (5, 5));
    assert_eq!(check(&imported.schema), vec![]);
    let written = generate(&imported.schema);
    assert_eq!(import(&written).expect("read back").schema, imported.schema, "{written}");
}

#[test]
fn namespaces_nest_and_names_keep_their_case() {
    let s = read().schema;
    let names: Vec<(&str, Option<&str>)> =
        s.namespaces.iter().map(|n| (n.name.as_str(), n.parent.as_ref().map(|p| p.as_str()))).collect();
    assert_eq!(names, [("lake", None), ("shop", Some("n_lake"))]);
}

#[test]
fn columns_types_and_field_ids() {
    let s = read().schema;
    let orders = s.tables.iter().find(|t| t.name == "orders").expect("orders");
    let ids: Vec<i32> = orders.columns.iter().filter_map(|c| c.field_id).collect();
    assert_eq!(ids, (1..=10).collect::<Vec<_>>(), "top-level columns first");
    let lines = &orders.columns[4].data_type;
    assert_eq!((lines.name.as_str(), lines.element_id), ("list", Some(11)), "then nested, in order");
    let item = lines.of.as_deref().expect("element");
    let fields: Vec<(&str, i32, bool)> =
        item.fields.iter().map(|f| (f.name.as_str(), f.field_id, f.nullable)).collect();
    assert_eq!(
        fields,
        [("sku", 12, false), ("qty", 13, true), ("price", 14, true)],
        "a struct's fields, then into each"
    );
    assert_eq!(item.fields[2].comment.as_deref(), Some("unit price"));
    let attrs = &orders.columns[5].data_type;
    assert_eq!((attrs.name.as_str(), attrs.key_id, attrs.element_id), ("map", Some(15), Some(16)));
    assert_eq!(orders.columns[3].comment.as_deref(), Some("the order's total, tax included"));
    assert_eq!(orders.columns[8].data_type.name, "timestamptz", "Spark TIMESTAMP is zoned");
    assert_eq!(orders.columns[9].data_type.name, "timestamp", "TIMESTAMP_NTZ is not");
}

#[test]
fn iceberg_options_and_notes() {
    let s = read().schema;
    let orders = s.tables.iter().find(|t| t.name == "orders").expect("orders");
    let ice = orders.options.iceberg.as_ref().expect("iceberg");
    assert_eq!(ice.format_version, Some(3));
    let transforms: Vec<&str> = ice.partition_spec.iter().map(|p| p.transform.as_str()).collect();
    assert_eq!(transforms, ["month", "bucket[16]", "truncate[4]"]);
    assert_eq!(ice.properties.get("write.update.mode").map(String::as_str), Some("merge-on-read"));
    assert_eq!(ice.identifier_fields.iter().map(|i| i.as_str()).collect::<Vec<_>>(), ["c_orders_order_key"]);
    let order: Vec<(Direction, Nulls)> = ice.sort_order.iter().map(|o| (o.direction, o.nulls)).collect();
    assert_eq!(order, [(Direction::Asc, Nulls::First), (Direction::Desc, Nulls::First)]);
    assert_eq!(
        orders.notes.as_deref(),
        Some(
            "lake.shop.orders\nEvery version of every order, from the orders service through Debezium.\n\nMerge-on-read: updates arrive all day."
        )
    );
    let view = &s.views[0];
    assert_eq!((view.notes.as_deref(), view.reads.len()), (Some("Each order as it is now."), 1));
}
