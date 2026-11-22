//! The skeleton: its file, its engine sections, and its checks.

use schema_forge_model::{Id, Ids, Kind, Schema, check};

fn id(s: &str) -> Id {
    Id::try_from(s).expect("an id")
}

/// A schema of a made-up engine: two namespaces, a table, a view reading it, a link, an area, engine sections.
const SAMPLE: &str = r##"{
  "format": 2,
  "engine": { "id": "example", "version": "3" },
  "namespaces": [
    { "id": "n_lake", "name": "lake" },
    { "id": "n_lake_sales", "name": "sales", "parent": "n_lake", "engine": { "location": "s3://lake/sales" } }
  ],
  "objects": [
    {
      "id": "o_customers", "kind": "table", "namespace": "n_lake_sales", "name": "customers", "area": "a_people",
      "columns": [
        { "id": "c_customers_id", "name": "id", "type": "long", "null": false },
        { "id": "c_customers_email", "name": "email", "type": "string", "null": true, "comment": "where receipts go" }
      ]
    },
    {
      "id": "o_orders", "kind": "table", "namespace": "n_lake_sales", "name": "orders",
      "comment": "one row per order", "notes": "Landed from the shop.", "tags": ["cdc"],
      "columns": [
        { "id": "c_orders_id", "name": "id", "type": "long", "null": false, "engine": { "field_id": 1 } },
        { "id": "c_orders_customer", "name": "customer_id", "type": "long", "null": false, "engine": { "field_id": 2 } },
        { "id": "c_orders_total", "name": "total", "type": "decimal(18,2)", "null": true, "engine": { "field_id": 3 } }
      ],
      "engine": { "zeta": 1, "alpha": { "nested": [3, 2, 1] }, "partition_spec": [{ "source": "c_orders_id", "transform": "bucket[16]" }] }
    },
    {
      "id": "o_order_totals", "kind": "view", "namespace": "n_lake_sales", "name": "order_totals", "reads": ["o_orders"],
      "columns": [{ "id": "c_order_totals_total", "name": "total", "type": "decimal(38,2)", "null": true }],
      "engine": { "query": "select sum(total) as total from orders" }
    }
  ],
  "links": [
    {
      "id": "l_orders_customer", "name": "an order's customer",
      "from": { "object": "o_orders", "columns": ["c_orders_customer"] },
      "to": { "object": "o_customers", "columns": ["c_customers_id"] },
      "engine": { "enforced": false }
    }
  ],
  "areas": [{ "id": "a_people", "name": "People", "colour": "#cc66ff" }],
  "engine_section": { "catalog": "lakehouse" }
}"##;

fn sample() -> Schema {
    Schema::from_json(SAMPLE).expect("the sample reads")
}

#[test]
fn a_sound_schema_has_no_problems() {
    assert_eq!(check(&sample()), Vec::new());
    assert_eq!(check(&Schema::new("example", "1")), Vec::new(), "an empty schema is sound");
}

#[test]
fn the_file_reads_and_writes_back_the_same() {
    let s = sample();
    let text = s.to_json();
    let again = Schema::from_json(&text).expect("it reads back");
    assert_eq!(again, s);
    assert_eq!(again.to_json(), text, "the same schema is always the same text");
}

#[test]
fn engine_sections_are_kept_exactly_as_the_engine_wrote_them() {
    let s = sample();
    let orders = s.object(&id("o_orders")).expect("orders");
    let keys: Vec<&str> = orders.engine.keys().map(String::as_str).collect();
    assert_eq!(keys, ["zeta", "alpha", "partition_spec"], "in the engine's order, not sorted");
    assert_eq!(orders.engine["alpha"]["nested"], serde_json::json!([3, 2, 1]));
    assert_eq!(orders.columns[2].engine["field_id"], 3);
    let text = s.to_json();
    assert!(text.find("\"zeta\"").expect("zeta") < text.find("\"alpha\"").expect("alpha"));
    assert_eq!(s.engine_section["catalog"], "lakehouse");
}

#[test]
fn only_this_format_is_read() {
    let older = SAMPLE.replacen("\"format\": 2", "\"format\": 1", 1);
    assert_eq!(Schema::from_json(&older), Err("this is a format 1 schema; this version reads format 2".to_string()));
    assert!(Schema::from_json(r#"{"engine": {"id": "x", "version": "1"}}"#).is_err(), "no format");
    let unknown = SAMPLE.replacen("\"format\": 2,", "\"format\": 2, \"surprise\": true,", 1);
    assert!(Schema::from_json(&unknown).is_err(), "a field the skeleton does not have is refused");
    let bad_id = SAMPLE.replacen("\"n_lake\"", "\"N-Lake\"", 1);
    assert!(Schema::from_json(&bad_id).is_err(), "ids are checked as they are read");
}

#[test]
fn parts_are_found_by_id() {
    let s = sample();
    assert_eq!(s.path(&id("n_lake_sales")), ["lake", "sales"]);
    assert_eq!(s.path(&id("n_nowhere")), Vec::<&str>::new());
    let (o, c) = s.column(&id("c_orders_total")).expect("the column");
    assert_eq!((o.name.as_str(), c.name.as_str(), c.data_type.as_str()), ("orders", "total", "decimal(18,2)"));
    assert_eq!(s.object(&id("o_orders")).and_then(|o| o.column_named("customer_id")).map(|c| c.null), Some(false));
}

#[test]
fn new_ids_never_take_one_the_schema_has() {
    let s = sample();
    let mut ids = Ids::of(&s);
    assert_eq!(ids.next(Kind::Object, &["orders"]).as_str(), "o_orders_2");
    assert_eq!(ids.next(Kind::Column, &["orders", "id"]).as_str(), "c_orders_id_2");
    assert_eq!(ids.next(Kind::Object, &["refunds"]).as_str(), "o_refunds");
}

/// The problems of the sample after `change`, as text.
fn problems(change: impl FnOnce(&mut Schema)) -> Vec<String> {
    let mut s = sample();
    change(&mut s);
    check(&s).iter().map(ToString::to_string).collect()
}

#[test]
fn ids_are_used_once_across_the_schema() {
    let p = problems(|s| s.objects[0].columns[1].id = id("o_orders"));
    assert_eq!(p, ["o_orders: this id is used twice"]);
}

#[test]
fn namespaces_hold_together() {
    assert_eq!(
        problems(|s| s.namespaces[1].parent = Some(id("n_gone"))),
        ["n_lake_sales: its parent n_gone is not a namespace of the schema"]
    );
    let p = problems(|s| s.namespaces[0].parent = Some(id("n_lake_sales")));
    assert!(p.contains(&"n_lake: it is inside itself".to_string()), "{p:?}");
    assert!(p.contains(&"n_lake_sales: it is inside itself".to_string()), "{p:?}");
    let p = problems(|s| {
        s.namespaces[1].parent = None;
        s.namespaces[1].name = "lake".into();
    });
    assert_eq!(
        p,
        [
            "n_lake: another namespace beside it is called `lake`",
            "n_lake_sales: another namespace beside it is called `lake`"
        ]
    );
    assert_eq!(problems(|s| s.namespaces[0].name = " ".into()), ["n_lake: a namespace without a name"]);
}

#[test]
fn objects_hold_together() {
    assert_eq!(
        problems(|s| s.objects[0].namespace = id("n_gone")),
        ["o_customers: its namespace n_gone is not a namespace of the schema"]
    );
    let p = problems(|s| s.objects[0].name = "orders".into());
    assert_eq!(p.len(), 2, "both objects called `orders` are named: {p:?}");
    assert_eq!(
        problems(|s| {
            s.objects[0].name = "orders".into();
            s.objects[0].namespace = id("n_lake");
        }),
        Vec::<String>::new(),
        "the same name in another namespace is fine"
    );
    assert_eq!(
        problems(|s| s.objects[0].area = Some(id("a_gone"))),
        ["o_customers: its area a_gone is not an area of the schema"]
    );
    assert_eq!(
        problems(|s| s.objects[2].reads.push(id("o_gone"))),
        ["o_order_totals: it reads o_gone, which is not an object of the schema"]
    );
    assert_eq!(problems(|s| s.objects[2].reads = vec![id("o_order_totals")]), ["o_order_totals: it reads itself"]);
    assert_eq!(problems(|s| s.objects[1].kind = String::new()), ["o_orders: an object without a kind"]);
}

#[test]
fn columns_hold_together() {
    assert_eq!(
        problems(|s| s.objects[1].columns[2].name = "id".into()),
        ["c_orders_total: `orders` has another column called `id`"]
    );
    assert_eq!(
        problems(|s| s.objects[1].columns[2].name = "ID".into()),
        Vec::<String>::new(),
        "case is the engine's rule"
    );
    assert_eq!(
        problems(|s| s.objects[1].columns[2].data_type = String::new()),
        ["c_orders_total: a column without a type"]
    );
}

#[test]
fn links_hold_together() {
    assert_eq!(
        problems(|s| s.links[0].to.object = id("o_gone")),
        ["l_orders_customer: it links to o_gone, which is not an object of the schema"]
    );
    assert_eq!(
        problems(|s| s.links[0].to.columns = vec![id("c_orders_id")]),
        ["l_orders_customer: it links to c_orders_id, which is not a column of `customers`"]
    );
    let p = problems(|s| s.links[0].to.columns.push(id("c_customers_email")));
    assert_eq!(p, ["l_orders_customer: it links 1 columns to 2"]);
    let p = problems(|s| {
        s.links[0].from.columns.clear();
        s.links[0].to.columns.clear();
    });
    assert_eq!(p, ["l_orders_customer: it links from no columns", "l_orders_customer: it links to no columns"]);
}

#[test]
fn the_schema_names_its_engine_and_areas_are_distinct() {
    assert_eq!(problems(|s| s.engine.id = String::new()), ["the schema names no engine"]);
    assert_eq!(problems(|s| s.engine.version = " ".into()), ["the schema names no version of its engine"]);
    let p = problems(|s| {
        let mut a = s.areas[0].clone();
        a.id = id("a_people_2");
        s.areas.push(a);
    });
    assert_eq!(p, ["a_people_2: another area is called `People`"]);
}
