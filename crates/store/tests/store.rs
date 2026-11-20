//! The store, held to docs/store.md: a model saved comes back identical, every change is logged and
//! announced, and the file keeps it all across reopening.

use schema_forge_core::{Schema, Target, hash};
use schema_forge_store::{Error, Store};

fn fixture(name: &str) -> Schema {
    let path = format!("{}/../core/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("schema")
}

#[test]
fn a_saved_model_comes_back_identical_and_survives_reopening() {
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("store.redb");
    for (name, file, target) in
        [("orders", "orders_postgres.json", Target::Postgres), ("lake", "orders_iceberg.json", Target::Iceberg)]
    {
        let model = fixture(file);
        {
            let store = Store::open(&path).expect("open");
            store.create_schema(name, target).expect("create");
            let mut heard = store.subscribe();
            let op = store.replace_model(name, &model, "import", "import").expect("save");
            assert_eq!(op.sequence, 1);
            assert_eq!(store.model(name).expect("load"), model, "{name} comes back identical");
            let change = heard.try_recv().expect("the change is announced");
            assert_eq!((change.schema.as_str(), change.operation), (name, op));
        }
        let store = Store::open(&path).expect("reopen");
        let back = store.model(name).expect("load after reopening");
        assert_eq!(hash(&back), hash(&model), "{name} survives reopening");
    }
    let store = Store::open(&path).expect("reopen");
    let names: Vec<String> = store.schemas().expect("schemas").into_iter().map(|s| s.name).collect();
    assert_eq!(names, ["lake", "orders"]);
}

#[test]
fn every_change_is_logged_in_order() {
    let dir = tempfile::tempdir().expect("dir");
    let store = Store::open(&dir.path().join("store.redb")).expect("open");
    store.create_schema("orders", Target::Postgres).expect("create");
    let model = fixture("orders_postgres.json");
    store.replace_model("orders", &model, "import", "import").expect("first");
    let mut smaller = model.clone();
    smaller.views.clear();
    store.replace_model("orders", &smaller, "import", "file").expect("second");
    let ops = store.operations("orders").expect("log");
    assert_eq!(ops.iter().map(|o| (o.sequence, o.by.as_str())).collect::<Vec<_>>(), [(1, "import"), (2, "file")]);
    assert_eq!(store.model("orders").expect("load"), smaller, "the second replaces the first, nothing left over");
}

#[test]
fn schemas_whose_names_share_a_prefix_stay_apart() {
    let dir = tempfile::tempdir().expect("dir");
    let store = Store::open(&dir.path().join("store.redb")).expect("open");
    for name in ["orders", "orders-archive", "orders_2"] {
        store.create_schema(name, Target::Postgres).expect("create");
    }
    let model = fixture("orders_postgres.json");
    store.replace_model("orders", &model, "import", "import").expect("save");
    assert_eq!(store.model("orders").expect("load"), model);
    assert_eq!(store.model("orders-archive").expect("load"), Schema::new(Target::Postgres));
    assert_eq!(store.model("orders_2").expect("load"), Schema::new(Target::Postgres));
    assert!(store.operations("orders-archive").expect("log").is_empty());
}

#[test]
fn what_is_refused() {
    let dir = tempfile::tempdir().expect("dir");
    let store = Store::open(&dir.path().join("store.redb")).expect("open");
    store.create_schema("orders", Target::Postgres).expect("create");
    assert!(matches!(store.create_schema("orders", Target::Mysql), Err(Error::SchemaExists(_))));
    for bad in ["", "Orders", "1orders", "or ders", "orders/x"] {
        assert!(matches!(store.create_schema(bad, Target::Mysql), Err(Error::BadName(_))), "{bad:?}");
    }
    assert!(matches!(store.model("nowhere"), Err(Error::NoSchema(_))));
    let iceberg = fixture("orders_iceberg.json");
    assert!(matches!(store.replace_model("orders", &iceberg, "import", "import"), Err(Error::WrongTarget { .. })));
}

#[test]
fn rules_are_linked_checked_logged_and_kept() {
    use schema_forge_core::rules::{Group, Link, Scope};
    use schema_forge_store::Rules;
    let dir = tempfile::tempdir().expect("dir");
    let path = dir.path().join("store.redb");
    let model = fixture("orders_iceberg.json");
    let table = model.tables[0].id.clone();
    let link = |rule: &str, at: Scope| Link { rule: rule.to_string(), at, off: false, locked: false, reason: None };
    {
        let store = Store::open(&path).expect("open");
        store.create_schema("lake", Target::Iceberg).expect("create");
        store.replace_model("lake", &model, "import", "import").expect("save");
        let mut heard = store.subscribe();
        store.link_rule(Rules::Global, Link { locked: true, ..link("pk", Scope::Global) }, "you").expect("global");
        assert_eq!(heard.try_recv().expect("announced").schema, "*");
        store.link_rule(Rules::Schema("lake"), link("norm", Scope::Schema), "you").expect("link");
        let op = store
            .set_group("lake", Group { name: "hot".to_string(), tables: vec![table.clone()] }, "you")
            .expect("group");
        assert_eq!(op.kind, "set_group");
        store
            .link_rule(Rules::Schema("lake"), link("cdc", Scope::Group { group: "hot".to_string() }), "you")
            .expect("on the group");
        // Refused: an unknown rule, a missing level, a locked rule switched off, an exception without a reason.
        let refused = |l: Link| matches!(store.link_rule(Rules::Schema("lake"), l, "you"), Err(Error::Rule(_)));
        assert!(refused(link("nope", Scope::Schema)));
        assert!(refused(link("norm", Scope::Group { group: "cold".to_string() })));
        assert!(refused(Link { off: true, reason: Some("no".to_string()), ..link("pk.ident", Scope::Schema) }));
        assert!(refused(Link { off: true, ..link("norm", Scope::Table { table: table.clone() }) }));
        assert!(refused(link("norm", Scope::Global)), "a global link goes through Rules::Global");
        assert!(matches!(store.remove_group("lake", "hot", "you"), Err(Error::Rule(_))), "rules are linked to it");
        store
            .link_rule(
                Rules::Schema("lake"),
                Link {
                    off: true,
                    reason: Some("kept as the source sends it".to_string()),
                    ..link("norm.copies", Scope::Table { table: table.clone() })
                },
                "you",
            )
            .expect("an exception with a reason");
        let kinds: Vec<String> = store.operations("lake").expect("log").into_iter().map(|o| o.kind).collect();
        assert_eq!(kinds, ["import", "link_rule", "set_group", "link_rule", "link_rule"]);
    }
    let store = Store::open(&path).expect("reopen");
    let set = store.rules("lake").expect("rules");
    assert_eq!(set.links.len(), 3);
    assert_eq!(set.groups[0].tables, std::slice::from_ref(&table));
    assert_eq!(store.global_rules().expect("global").len(), 1);
    store.unlink_rule(Rules::Schema("lake"), "cdc", &Scope::Group { group: "hot".to_string() }, "you").expect("unlink");
    store.remove_group("lake", "hot", "you").expect("now it can go");
    assert!(store.unlink_rule(Rules::Schema("lake"), "cdc", &Scope::Schema, "you").is_err(), "nothing linked there");
    assert!(matches!(store.rules("nowhere"), Err(Error::NoSchema(_))));
}
