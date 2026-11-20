//! The shape of a schema, held to docs/perspectives.md: families from names, copies stacked under one table,
//! links declared or read from column names and descriptions, and shared keys kept off the lines.

use schema_forge_core::{Schema, shape};
use serde_json::{Value, json};

fn column(table: &str, name: &str, comment: Option<&str>) -> Value {
    let mut c = json!({ "id": format!("c_{}_{}", table.to_lowercase(), name.to_lowercase()), "name": name, "type": { "name": "string" }, "nullable": true });
    if let Some(text) = comment {
        c["comment"] = json!(text);
    }
    c
}

fn table(ns: &str, name: &str, columns: &[(&str, Option<&str>)]) -> Value {
    json!({
        "id": format!("t_{}", name.to_lowercase()),
        "namespace": ns,
        "name": name,
        "columns": columns.iter().map(|(c, comment)| column(name, c, *comment)).collect::<Vec<_>>(),
    })
}

/// A namespace named with `prefix__` families, a `tbl_` namespace with dated copies, and a small one.
fn schema() -> Schema {
    let mut tables = vec![
        table("n_estate", "nodes", &[("id", None)]),
        table("n_estate", "databases", &[("id", None), ("node_id", None)]),
        table("n_estate", "annotations", &[("id", None), ("subject_id", Some("the row it describes in databases"))]),
    ];
    for n in ["accounts", "host", "logs", "status", "variables"] {
        tables.push(table("n_estate", &format!("node__{n}"), &[("id", None), ("node_id", None)]));
    }
    for n in ["a", "b", "c", "d", "e", "f"] {
        tables.push(table("n_estate", &format!("misc_{n}"), &[("id", None)]));
    }
    tables.push(table("n_report", "tbl_Stores", &[("StoreKey", None)]));
    tables.push(table("n_report", "tbl_Promotions", &[("PromotionID", None), ("StoreKey", None)]));
    for m in ["202203", "202204", "202205"] {
        tables.push(table("n_report", &format!("tbl_ShipLog{m}"), &[("StoreKey", None)]));
    }
    tables.push(table("n_report", "tbl_Sales", &[("StoreKey", None), ("PromotionID", None)]));
    tables.push(table("n_report", "tbl_Sales_old", &[("StoreKey", None)]));
    for n in ["Shop", "ShopLogins", "ShopVisits", "ShopCarts", "ShopAudit"] {
        tables.push(table("n_report", &format!("tbl_{n}"), &[("StoreKey", None)]));
    }
    for i in 0..30 {
        tables.push(table(
            "n_report",
            &format!("tbl_Stock{}x", ["A", "B", "C", "D", "E", "F"][i % 6].repeat(i / 6 + 1)),
            &[("StoreKey", None)],
        ));
    }
    tables.push(table("n_small", "orders", &[("id", None), ("customer_id", None)]));
    tables.push(table("n_small", "customers", &[("id", None)]));
    serde_json::from_value(json!({
        "format": 1,
        "target": "iceberg",
        "namespaces": [{ "id": "n_estate", "name": "estate" }, { "id": "n_report", "name": "report" }, { "id": "n_small", "name": "small" }],
        "tables": tables,
        "relationships": [{ "id": "r_orders_customer", "from": { "table": "t_orders", "columns": ["c_orders_customer_id"] }, "to": { "table": "t_customers", "columns": ["c_customers_id"] }, "enforced": false }],
    }))
    .expect("a schema")
}

fn family_of(s: &schema_forge_core::Shape, table: &str) -> String {
    s.tables.iter().find(|t| t.table.as_str() == table).expect(table).family.clone()
}

#[test]
fn families_come_from_the_names() {
    let s = shape(&schema());
    assert_eq!(family_of(&s, "t_node__host"), "node__", "a prefix__ makes a family");
    assert_eq!(family_of(&s, "t_misc_a"), "misc", "the first word, shared by enough tables");
    assert_eq!(family_of(&s, "t_nodes"), "ungrouped", "a word too few tables share");
    assert_eq!(family_of(&s, "t_tbl_shoplogins"), "Shop", "the word after a prefix most names share");
    assert_eq!(family_of(&s, "t_orders"), "tables", "a small namespace is one family");
}

#[test]
fn copies_stack_under_the_plainest_name() {
    let s = shape(&schema());
    let log = s.tables.iter().find(|t| t.table.as_str() == "t_tbl_shiplog202203").expect("the first log");
    let stack = log.stack.as_ref().expect("a stack");
    assert_eq!(stack.count, 3);
    assert_eq!(stack.label, "tbl_ShipLog · 3 monthly, 2022-03 → 2022-05");
    let copy = s.tables.iter().find(|t| t.table.as_str() == "t_tbl_shiplog202205").expect("a copy");
    assert_eq!(copy.copy_of.as_ref().map(schema_forge_core::Id::as_str), Some("t_tbl_shiplog202203"));
    let old = s.tables.iter().find(|t| t.table.as_str() == "t_tbl_sales_old").expect("_old");
    assert_eq!(old.copy_of.as_ref().map(schema_forge_core::Id::as_str), Some("t_tbl_sales"));
    let sales = s.tables.iter().find(|t| t.table.as_str() == "t_tbl_sales").expect("sales");
    assert_eq!(sales.stack.as_ref().map(|k| k.label.as_str()), Some("tbl_Sales · 2 copies"));
}

#[test]
fn links_are_declared_or_read_from_names_and_descriptions() {
    let s = shape(&schema());
    let has = |from: &str, col: &str, to: &str| {
        s.links.iter().find(|l| l.from.as_str() == from && l.column.as_str() == col && l.to.as_str() == to)
    };
    let declared = has("t_orders", "c_orders_customer_id", "t_customers").expect("the declared one");
    assert!(declared.declared && !declared.shared);
    assert!(has("t_node__host", "c_node__host_node_id", "t_nodes").is_some_and(|l| !l.declared), "node_id names nodes");
    assert!(
        has("t_tbl_sales", "c_tbl_sales_promotionid", "t_tbl_promotions").is_some(),
        "PromotionID names tbl_Promotions"
    );
    assert!(
        has("t_annotations", "c_annotations_subject_id", "t_databases").is_some(),
        "the description names the table"
    );
    assert!(s.links.iter().all(|l| l.from.as_str() != "t_tbl_shiplog202204"), "copies draw no links of their own");
    assert!(s.links.iter().all(|l| l.from != l.to), "a table's own key is not a link");
}

#[test]
fn a_key_most_tables_carry_is_shared_not_drawn() {
    let s = shape(&schema());
    let into_stores: Vec<_> = s.links.iter().filter(|l| l.to.as_str() == "t_tbl_stores").collect();
    assert!(into_stores.len() > 25);
    assert!(into_stores.iter().all(|l| l.shared), "StoreKey everywhere is a shared key");
    assert!(s.links.iter().filter(|l| l.to.as_str() == "t_nodes").all(|l| !l.shared), "nodes is a hub, not shared");
}
