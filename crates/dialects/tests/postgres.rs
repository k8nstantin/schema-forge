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

/// The cases a review found: partitions with keys of their own, series whose children are pointed at,
/// interleaved attaches, foreign keys from partitioned tables, domains with DEFAULT NULL and bare CHECK, and
/// foreign keys to unique indexes or keys listed in another order.
#[test]
fn partitions_domains_and_keys_hold_together() {
    let mut sql = String::from(
        "CREATE TABLE public.customers (id bigint NOT NULL, email text, a int, b int);\n\
         ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_pkey PRIMARY KEY (id);\n\
         CREATE UNIQUE INDEX customers_a_b ON public.customers USING btree (a, b);\n\
         ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_b_a UNIQUE (b, a);\n\
         CREATE TABLE public.notes (id bigint NOT NULL, ca int, cb int);\n\
         ALTER TABLE ONLY public.notes ADD CONSTRAINT notes_to_index FOREIGN KEY (ca, cb) REFERENCES public.customers(a, b);\n\
         CREATE DOMAIN public.maybe AS text DEFAULT NULL NOT NULL;\n\
         CREATE DOMAIN public.positive AS integer CHECK (VALUE > 0);\n\
         CREATE TABLE public.events (id bigint NOT NULL, customer_id bigint, happened_on date NOT NULL) PARTITION BY RANGE (happened_on);\n\
         CREATE TABLE public.logs (id bigint NOT NULL, happened_on date NOT NULL) PARTITION BY RANGE (happened_on);\n\
         CREATE SEQUENCE public.events_seq;\n",
    );
    // A lone partition with a key of its own, and a daily series interleaved with another parent's.
    sql.push_str(
        "CREATE TABLE public.events_default (id bigint NOT NULL, customer_id bigint, happened_on date NOT NULL);\n",
    );
    for d in 1..=5 {
        sql.push_str(&format!("CREATE TABLE public.events_2025_01_0{d} (id bigint NOT NULL, customer_id bigint, happened_on date NOT NULL);\n"));
        sql.push_str(&format!(
            "CREATE TABLE public.logs_2025_01_0{d} (id bigint NOT NULL, happened_on date NOT NULL);\n"
        ));
    }
    for d in 1..=5 {
        sql.push_str(&format!("ALTER TABLE ONLY public.events ATTACH PARTITION public.events_2025_01_0{d} FOR VALUES FROM ('2025-01-0{d}') TO ('2025-01-0{}');\n", d + 1));
        sql.push_str(&format!("ALTER TABLE ONLY public.logs ATTACH PARTITION public.logs_2025_01_0{d} FOR VALUES FROM ('2025-01-0{d}') TO ('2025-01-0{}');\n", d + 1));
    }
    sql.push_str("ALTER TABLE ONLY public.events ATTACH PARTITION public.events_default DEFAULT;\n");
    sql.push_str("ALTER TABLE ONLY public.events_default ADD CONSTRAINT events_default_pkey PRIMARY KEY (id);\n");
    sql.push_str("CREATE INDEX events_default_customer ON public.events_default USING btree (customer_id);\n");
    sql.push_str("ALTER SEQUENCE public.events_seq OWNED BY public.events_2025_01_01.id;\n");
    sql.push_str("ALTER TABLE ONLY public.events_2025_01_02 ADD CONSTRAINT day_fk FOREIGN KEY (customer_id) REFERENCES public.customers(id);\n");
    sql.push_str("ALTER TABLE public.events ADD CONSTRAINT events_customer_fk FOREIGN KEY (customer_id) REFERENCES public.customers(id);\n");

    let read = import(&sql).expect("import");
    let s = &read.schema;
    assert!(check(s).is_empty(), "the model keeps its rules: {:?}", check(s));
    // The lone partition with its own key stays a table with its columns; its ATTACH is kept as written.
    let default = table(s, "events_default");
    assert!(default.partition_of.is_none() && default.columns.len() == 3 && default.primary_key.is_some());
    assert!(s.kept.iter().any(|k| k.text.contains("ATTACH PARTITION public.events_default DEFAULT")));
    // Each parent folded once; nothing points at a folded child.
    assert_eq!(s.kept.iter().filter(|k| k.kind == KeptKind::Partitions && k.text.contains("events_2025")).count(), 1);
    assert_eq!(s.kept.iter().filter(|k| k.kind == KeptKind::Partitions && k.text.contains("logs_2025")).count(), 1);
    assert!(
        s.relationships.iter().all(|r| s.tables.iter().any(|t| t.id == r.from.table)),
        "no link from a folded child"
    );
    assert!(s.sequences.iter().all(|q| q.owned_by.is_none()), "the owner went with the series");
    assert!(s.kept.iter().any(|k| k.text.contains("OWNED BY") && k.text.contains("events_2025_01_01")));
    // Domains.
    let domain = |n: &str| match &s.types.iter().find(|t| t.name == n).expect(n).kind {
        TypeKind::Domain { default, checks, not_null, .. } => (default.clone(), checks.len(), *not_null),
        other => panic!("{other:?}"),
    };
    assert_eq!(domain("maybe"), (Some("NULL".to_string()), 0, true));
    assert_eq!(domain("positive"), (None, 1, false));

    let out = schema_forge_dialects::postgres::generate(s);
    assert!(
        out.contains("ALTER TABLE public.events\n    ADD CONSTRAINT events_customer_fk"),
        "no ONLY on a partitioned table"
    );
    assert!(
        !out.contains("(\"\")") && !out.contains("ALTER TABLE ONLY \n") && !out.contains("OWNED BY ;"),
        "nothing names a removed column"
    );
    assert!(out.contains("DEFAULT NULL NOT NULL"));
    let again = import(&out).expect("read back").schema;
    assert!(check(&again).is_empty(), "{:?}", check(&again));
}
