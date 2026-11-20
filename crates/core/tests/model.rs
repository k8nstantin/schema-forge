//! The model, held to its design: the worked examples read, keep every rule, round-trip exactly, hash
//! stably; and each of the model's own rules catches what it should.

use schema_forge_core::{Schema, Target, check, hash};

fn fixture(name: &str) -> (String, Schema) {
    let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(&path).expect("fixture");
    let schema: Schema = serde_json::from_str(&text).expect("the fixture reads as a schema");
    (text, schema)
}

fn as_value(text: &str) -> serde_json::Value {
    serde_json::from_str(text).expect("json")
}

#[test]
fn the_worked_examples_read_keep_every_rule_and_round_trip() {
    for name in ["orders_postgres.json", "orders_iceberg.json"] {
        let (text, schema) = fixture(name);
        assert_eq!(check(&schema), vec![], "{name} keeps every rule");
        let written = serde_json::to_string_pretty(&schema).expect("write");
        assert_eq!(as_value(&written), as_value(&text), "{name} is written back exactly");
        let again: Schema = serde_json::from_str(&written).expect("read back");
        assert_eq!(again, schema);
        assert_eq!(hash(&again), hash(&schema), "{name} hashes the same");
    }
}

#[test]
fn a_schema_with_unknown_fields_is_refused() {
    let err = serde_json::from_str::<Schema>(r#"{"format":1,"target":"mysql","tabels":[]}"#).unwrap_err();
    assert!(err.to_string().contains("unknown field `tabels`"), "{err}");
}

#[test]
fn the_hash_follows_content_not_key_order() {
    let (_, schema) = fixture("orders_postgres.json");
    let mut changed = schema.clone();
    changed.tables[0].comment = Some("Customers.".to_string());
    assert_ne!(hash(&changed), hash(&schema));
    // Written with keys in another order, the same schema hashes the same.
    let reordered = r#"{"target":"mysql","format":1}"#;
    let a: Schema = serde_json::from_str(reordered).expect("read");
    assert_eq!(hash(&a), hash(&Schema::new(Target::Mysql)));
}

/// Changes `orders_postgres.json` with `edit`, and returns the problems found.
fn problems_after(edit: impl FnOnce(&mut Schema)) -> Vec<String> {
    let (_, mut schema) = fixture("orders_postgres.json");
    edit(&mut schema);
    check(&schema).into_iter().map(|p| p.to_string()).collect()
}

fn found(problems: &[String], needle: &str) -> bool {
    problems.iter().any(|p| p.contains(needle))
}

#[test]
fn each_rule_catches_what_it_should() {
    let p = problems_after(|s| s.tables[1].columns[0].id = s.tables[0].columns[0].id.clone());
    assert!(found(&p, "used more than once"), "{p:?}");

    let p = problems_after(|s| s.views[0].name = "orders".to_string());
    assert!(found(&p, "also the name of `t_orders`"), "{p:?}");

    let p = problems_after(|s| s.tables[1].columns[1].name = "ORDER_KEY".to_string());
    assert!(found(&p, "name of another column"), "{p:?}");

    let p = problems_after(|s| s.tables[0].columns[0].nullable = true);
    assert!(found(&p, "primary key column cannot be nullable"), "{p:?}");

    let p = problems_after(|s| s.relationships[0].to.columns = vec![s.tables[0].columns[1].id.clone()]);
    assert!(p.is_empty(), "pointing at a unique key is fine: {p:?}");

    let p = problems_after(|s| {
        s.tables[0].uniques.clear();
        s.relationships[0].to.columns = vec![s.tables[0].columns[1].id.clone()];
    });
    assert!(found(&p, "primary or unique key of `customers`"), "{p:?}");

    let p = problems_after(|s| s.relationships[0].from.columns.push(s.tables[1].columns[1].id.clone()));
    assert!(found(&p, "same number of columns"), "{p:?}");

    let p = problems_after(|s| s.views[0].reads = vec!["t_nowhere".parse_id()]);
    assert!(found(&p, "not a table or view"), "{p:?}");

    let p = problems_after(|s| {
        let mut second = s.views[0].clone();
        second.id = "v_loop".parse_id();
        second.name = "loop".to_string();
        second.reads = vec![s.views[0].id.clone()];
        s.views[0].reads = vec!["v_loop".parse_id()];
        s.views.push(second);
    });
    assert!(found(&p, "reads itself"), "{p:?}");

    let p = problems_after(|s| s.target = Target::Iceberg);
    assert!(found(&p, "Iceberg has no enforced relationships"), "{p:?}");
    assert!(found(&p, "needs a field id"), "{p:?}");
    assert!(found(&p, "no indexes, checks or unique keys"), "{p:?}");

    let p =
        problems_after(|s| s.tables[0].primary_key.as_mut().expect("pk").columns = vec!["c_orders_total".parse_id()]);
    assert!(found(&p, "not one of its columns"), "{p:?}");
}

#[test]
fn iceberg_rules() {
    let (_, mut schema) = fixture("orders_iceberg.json");
    schema.tables[0].columns[2].data_type.fields[1].data_type.element_id = Some(4);
    let p: Vec<String> = check(&schema).into_iter().map(|p| p.to_string()).collect();
    assert!(found(&p, "field id 4 is used more than once"), "{p:?}");

    let (_, mut schema) = fixture("orders_iceberg.json");
    schema.tables[1].columns[3].data_type = schema_forge_core::DataType::named("double");
    schema.tables[1].options.iceberg.as_mut().expect("iceberg").identifier_fields.push("c_orders_total".parse_id());
    let p: Vec<String> = check(&schema).into_iter().map(|p| p.to_string()).collect();
    assert!(found(&p, "cannot be float or double"), "{p:?}");

    let (_, mut schema) = fixture("orders_iceberg.json");
    schema.tables[1].options.iceberg.as_mut().expect("iceberg").format_version = Some(2);
    schema.tables[1].columns[1].data_type = schema_forge_core::DataType::named("variant");
    let p: Vec<String> = check(&schema).into_iter().map(|p| p.to_string()).collect();
    assert!(found(&p, "`variant` needs Iceberg format version 3"), "{p:?}");
}

#[test]
fn only_the_targets_types_are_accepted() {
    let p = problems_after(|s| s.tables[0].columns[1].data_type = schema_forge_core::DataType::named("string"));
    assert!(found(&p, "`string` is not a type of this target"), "{p:?}");
    let p = problems_after(|s| s.tables[0].columns[1].data_type = schema_forge_core::DataType::verbatim("citext"));
    assert!(p.is_empty(), "a verbatim type is kept: {p:?}");
}

trait ParseId {
    fn parse_id(self) -> schema_forge_core::Id;
}

impl ParseId for &str {
    fn parse_id(self) -> schema_forge_core::Id {
        schema_forge_core::Id::try_from(self.to_string()).expect("a readable id")
    }
}
