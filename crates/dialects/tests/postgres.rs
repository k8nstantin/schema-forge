//! Reading real pg_dump 17 output (tests/fixtures/postgres, made by tools/pg_fixtures.sh from source.sql).

use schema_forge_core::{Action, Direction, KeptKind, Nulls, Schema, TypeKind, check};
use schema_forge_dialects::postgres::import;

fn read(name: &str) -> schema_forge_dialects::Imported {
    let path = format!("{}/tests/fixtures/postgres/{name}", env!("CARGO_MANIFEST_DIR"));
    import(&std::fs::read_to_string(path).expect("fixture")).expect("import")
}

fn table<'a>(s: &'a Schema, name: &str) -> &'a schema_forge_core::Table {
    s.tables.iter().find(|t| t.name == name).unwrap_or_else(|| panic!("no table {name}"))
}

#[test]
fn every_statement_is_accounted_for_and_the_model_keeps_its_rules() {
    for name in ["schema.sql", "full.sql"] {
        let imported = read(name);
        let r = &imported.report;
        assert!(r.adds_up(), "{name}: {r}");
        assert!(r.not_understood.is_empty(), "{name}: {r}");
        assert_eq!(r.partition_series, 1, "{name}");
        assert_eq!(check(&imported.schema), vec![], "{name}");
    }
    let full = read("full.sql").report;
    assert!(full.data > 0 && full.copy_rows == 4, "{full}");
}

#[test]
fn both_dumps_give_the_same_model() {
    let (a, b) = (read("schema.sql").schema, read("full.sql").schema);
    let without_kept = |s: &Schema| Schema { kept: Vec::new(), ..s.clone() };
    assert_eq!(without_kept(&a), without_kept(&b));
}

#[test]
fn tables_keys_and_relationships() {
    let s = read("schema.sql").schema;
    let names: Vec<&str> = s.tables.iter().map(|t| t.name.as_str()).collect();
    for expected in ["invoices", "orders", "customers", "events", "events_default", "regions_data_eu"] {
        assert!(names.contains(&expected), "{names:?}");
    }
    assert!(!names.iter().any(|n| n.starts_with("events_2025")), "the daily partitions are a series: {names:?}");

    let customers = table(&s, "customers");
    let id = customers.columns.iter().find(|c| c.name == "id").expect("id");
    let identity = id.identity.as_ref().expect("identity");
    assert!(
        identity.always && identity.options.as_deref().unwrap_or("").contains("SEQUENCE NAME public.customers_id_seq")
    );
    let email = customers.columns.iter().find(|c| c.name == "email").expect("email");
    assert_eq!(email.comment.as_deref(), Some("Unique, lowercased."));
    assert_eq!(customers.uniques[0].name.as_deref(), Some("customers_email_key"));

    let orders = table(&s, "orders");
    assert_eq!(orders.comment.as_deref(), Some("Every version of every order."));
    let tax = orders.columns.iter().find(|c| c.name == "tax").expect("tax");
    assert_eq!(tax.generated.as_ref().map(|g| g.expression.as_str()), Some("round((total * 0.2), 2)"));
    let checks: Vec<&str> = orders.checks.iter().map(|c| c.expression.as_str()).collect();
    assert!(checks.contains(&"(total >= (0)::numeric)"), "{checks:?}");
    let partial = orders.indexes.iter().find(|i| i.name == "orders_current_idx").expect("partial");
    assert_eq!(partial.predicate.as_deref(), Some("(valid_to IS NULL)"));
    let expr = orders.indexes.iter().find(|i| i.name == "orders_lower_no_idx").expect("expression");
    assert_eq!(expr.parts[0].expression.as_deref(), Some("lower(order_no)"));
    assert_eq!((expr.parts[0].direction, expr.parts[0].nulls), (Some(Direction::Desc), Some(Nulls::Last)));

    let fk = s.relationships.iter().find(|r| r.name.as_deref() == Some("invoices_order_fkey")).expect("fk");
    assert_eq!((fk.on_update, fk.on_delete, fk.enforced), (Some(Action::Cascade), Some(Action::Cascade), true));
    let fk = s.relationships.iter().find(|r| r.name.as_deref() == Some("orders_customer_id_fkey")).expect("fk");
    assert_eq!(fk.on_delete, Some(Action::Restrict));
}

#[test]
fn partitions_series_and_designed() {
    let s = read("schema.sql").schema;
    let events = table(&s, "events");
    let pg = events.options.postgres.as_ref().expect("postgres options");
    assert_eq!(pg.partition_by.as_deref(), Some("RANGE (happened_on)"));
    let series = pg.partition_policy.as_ref().and_then(|p| p.series.as_ref()).expect("series");
    assert_eq!((series.interval.as_str(), series.first.as_str(), series.count), ("1 day", "2025-01-01", 7));
    let kept = s.kept.iter().find(|k| k.id == series.kept).expect("kept series");
    assert_eq!(kept.kind, KeptKind::Partitions);
    assert_eq!(kept.text.matches("ATTACH PARTITION").count(), 7);
    assert_eq!(kept.text.matches("OWNER TO").count(), 7, "each partition's owner goes with it");
    let default = table(&s, "events_default").partition_of.as_ref().expect("designed");
    assert_eq!((default.parent.as_str(), default.bounds.as_str()), ("t_events", "DEFAULT"));
    let eu = table(&s, "regions_data_eu").partition_of.as_ref().expect("designed");
    assert_eq!(eu.bounds, "FOR VALUES IN ('eu')");
}

#[test]
fn views_sequences_and_types() {
    let s = read("schema.sql").schema;
    let current = s.views.iter().find(|v| v.name == "current_orders").expect("view");
    assert_eq!(current.reads.iter().map(|r| r.as_str()).collect::<Vec<_>>(), ["t_orders"]);
    assert_eq!(current.comment.as_deref(), Some("Each order as it is now."));
    assert!(current.definition.starts_with("SELECT order_no"), "{}", current.definition);

    let revenue = s.views.iter().find(|v| v.name == "revenue_by_day").expect("matview");
    let pg = revenue.options.postgres.as_ref().expect("options");
    assert!(pg.materialized && !pg.with_data);
    assert_eq!(pg.indexes[0].parts[0].expression.as_deref(), Some("issued_on"));
    assert_eq!(revenue.reads.iter().map(|r| r.as_str()).collect::<Vec<_>>(), ["t_invoices"]);

    let invoice_no = s.sequences.iter().find(|q| q.name == "invoice_no").expect("sequence");
    assert_eq!((invoice_no.start, invoice_no.cache), (Some(1000), Some(10)));
    assert_eq!(invoice_no.owned_by.as_ref().map(|i| i.as_str()), Some("c_invoices_id"));

    let status = s.types.iter().find(|t| t.name == "order_status").expect("enum");
    assert_eq!(
        status.kind,
        TypeKind::Enum { values: vec!["new".into(), "paid".into(), "shipped".into(), "cancelled".into()] }
    );
    let domain = s.types.iter().find(|t| t.name == "positive_amount").expect("domain");
    let TypeKind::Domain { checks, .. } = &domain.kind else { panic!("domain") };
    assert_eq!(checks[0], "CONSTRAINT positive_amount_check CHECK ((VALUE > (0)::numeric))");
    let address = s.types.iter().find(|t| t.name == "address").expect("composite");
    let TypeKind::Composite { fields } = &address.kind else { panic!("composite") };
    assert_eq!((fields[2].data_type.name.as_str(), fields[2].data_type.length), ("varchar", Some(16)));
}

#[test]
fn what_is_kept_verbatim() {
    let s = read("schema.sql").schema;
    assert!(s.kept[0].text.starts_with("\\restrict "), "pg_dump's psql guard stays first");
    assert!(s.kept.iter().any(|k| k.kind == KeptKind::Function && k.text.contains("NEW.valid_from := now();")));
    let trigger = s.kept.iter().find(|k| k.kind == KeptKind::Trigger).expect("trigger");
    assert_eq!(trigger.refers_to.iter().map(|r| r.as_str()).collect::<Vec<_>>(), ["t_orders"]);
}
