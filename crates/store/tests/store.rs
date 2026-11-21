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
            let start = store.changes_since(None).last;
            let op = store.replace_model(name, &model, "import", "import").expect("save");
            assert_eq!(op.sequence, 1);
            assert_eq!(store.model(name).expect("load"), model, "{name} comes back identical");
            let change = store.changes_since(Some(start)).changes.pop().expect("the change is announced").1;
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
    let link = |rule: &str, at: Scope| Link {
        rule: rule.to_string(),
        at,
        off: false,
        locked: false,
        reason: None,
        enforce: None,
    };
    {
        let store = Store::open(&path).expect("open");
        store.create_schema("lake", Target::Iceberg).expect("create");
        store.replace_model("lake", &model, "import", "import").expect("save");
        let start = store.changes_since(None).last;
        store.link_rule(Rules::Global, Link { locked: true, ..link("pk", Scope::Global) }, "you").expect("global");
        assert_eq!(store.changes_since(Some(start)).changes[0].1.schema, "*", "announced");
        store.link_rule(Rules::Schema("lake"), link("norm", Scope::Schema), "you").expect("link");
        let op = store
            .set_group("lake", Group { name: "hot".to_string(), tables: vec![table.clone()] }, true, "you")
            .expect("group");
        let again = Group { name: "hot".to_string(), tables: vec![] };
        assert!(store.set_group("lake", again.clone(), true, "you").is_err(), "a new group never replaces one");
        let cold = Group { name: "cold".to_string(), ..again };
        assert!(store.set_group("lake", cold, false, "you").is_err(), "only a group there is can change");
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
    // A goal links what is not in place, all at once; `pk` is linked to every schema already.
    let op = store.link_packs("lake", &["norm", "pk", "cdc"], None, "you").expect("packs").expect("a change");
    assert_eq!(op.change, serde_json::json!({ "packs": ["cdc"] }));
    assert!(store.link_packs("lake", &["norm", "cdc"], None, "you").expect("packs").is_none(), "nothing left to link");
    // Every rule switched off for every schema: `*` is no catalog rule, but it is a link; without a reason it is not.
    let all = Link {
        off: true,
        reason: Some("a scratch workspace".to_string()),
        ..link(schema_forge_core::rules::ALL, Scope::Global)
    };
    let bare = Link { reason: None, ..all.clone() };
    assert!(matches!(store.link_rule(Rules::Global, bare, "you"), Err(Error::Rule(_))));
    store.link_rule(Rules::Global, all, "you").expect("every rule off");
}

#[test]
fn proposals_wait_for_approval_and_are_decided_once() {
    use schema_forge_core::rules::Enforce;
    use schema_forge_core::rules::Scope;
    use schema_forge_core::rules::custom::Sentence;
    use schema_forge_core::rules::review::{Proposed, Status};
    let dir = tempfile::tempdir().expect("dir");
    let store = Store::open(&dir.path().join("store.redb")).expect("open");
    store.create_schema("lake", Target::Iceberg).expect("create");
    store.replace_model("lake", &fixture("orders_iceberg.json"), "import", "import").expect("save");
    let new = |column: &str| Proposed::New {
        sentence: Sentence::HasColumn { column: column.into(), required: false, types: vec![] },
        targets: vec![],
    };
    let kept = store
        .propose(
            "lake",
            vec![
                (new("id"), Scope::Schema, Enforce::Soft, "seen".into()),
                (new("id"), Scope::Schema, Enforce::Soft, "again".into()),
            ],
            "agent",
        )
        .expect("proposed");
    assert_eq!(kept.iter().map(|p| p.id).collect::<Vec<_>>(), [1, 2]);
    assert!(store.rules("lake").expect("rules").links.is_empty(), "nothing holds before approval");
    store.set_proposal_enforce("lake", 1, Enforce::Hard, "you").expect("hard");
    let approved = store.decide("lake", 1, true, "you").expect("approved");
    assert_eq!((approved.status, approved.rule.as_deref()), (Status::Approved, Some("custom.1")));
    let set = store.rules("lake").expect("rules");
    assert_eq!(set.links[0].enforce, Some(Enforce::Hard));
    assert_eq!(store.custom_rules().expect("custom")[0].provenance.approved_by, "you");
    assert!(matches!(store.decide("lake", 1, true, "you"), Err(Error::Rule(_))), "decided once");
    assert!(matches!(store.decide("lake", 2, true, "you"), Err(Error::Rule(_))), "#2 repeats the rule #1 became");
    assert_eq!(store.decide("lake", 2, false, "you").expect("rejected").status, Status::Rejected);
}

#[test]
fn changes_apply_whole_are_refused_by_hard_rules_and_undo() {
    use schema_forge_core::DataType;
    use schema_forge_core::ops::{NewColumn, Op};
    use schema_forge_core::rules::{Enforce, Link, Scope};
    use schema_forge_store::Rules;
    let dir = tempfile::tempdir().expect("dir");
    let store = Store::open(&dir.path().join("store.redb")).expect("open");
    store.create_schema("lake", Target::Iceberg).expect("create");
    let col = |name: &str, ty: &str| NewColumn {
        name: name.into(),
        data_type: DataType::named(ty),
        nullable: true,
        default: None,
        comment: None,
    };
    let build = [
        Op::AddNamespace { name: "shop".into(), parent: None, comment: None },
        Op::AddTable {
            namespace: "shop".into(),
            name: "orders".into(),
            comment: Some("what was bought".into()),
            columns: vec![col("id", "string"), col("placed_at", "timestamptz")],
            primary_key: vec!["id".into()],
        },
    ];
    let made = store.change("lake", &build, false, "agent").expect("built");
    assert_eq!(made.summaries, ["added namespace `shop`", "added table `orders` with 2 columns"]);
    assert_eq!(store.model("lake").expect("model").tables.len(), 1);

    // A hard rule: descriptions, hard. A table without one is refused, and nothing of the batch lands.
    store
        .link_rule(
            Rules::Schema("lake"),
            Link {
                rule: "docs.table".into(),
                at: Scope::Schema,
                off: false,
                locked: false,
                reason: None,
                enforce: Some(Enforce::Hard),
            },
            "you",
        )
        .expect("linked");
    let bare = Op::AddTable {
        namespace: "shop".into(),
        name: "items".into(),
        comment: None,
        columns: vec![col("id", "string")],
        primary_key: vec![],
    };
    let refused = store.change(
        "lake",
        &[Op::RenameTable { table: "orders".into(), name: "sales".into() }, bare.clone()],
        false,
        "agent",
    );
    let Err(Error::Hard { message: why, rules }) = refused else { panic!("refused, not {refused:?}") };
    assert_eq!(rules, ["docs.table"]);
    assert!(why.contains("docs.table") && why.contains("items"), "{why}");
    assert_eq!(store.model("lake").expect("model").tables[0].name, "orders", "all or nothing");

    // Soft: the same break is highlighted, not refused.
    store.set_enforce(Rules::Schema("lake"), "docs.table", &Scope::Schema, Enforce::Soft, "you").expect("soft");
    let soft = store.change("lake", &[bare], false, "agent").expect("lands");
    assert_eq!(soft.soft.len(), 1, "the break is reported");

    // Destructive needs a yes; undo takes the latest change back, and only while it is still there.
    let drop = [Op::DropTable { table: "items".into() }];
    assert!(matches!(store.change("lake", &drop, false, "agent"), Err(Error::Destructive(_))));
    store.change("lake", &drop, true, "agent").expect("dropped");
    assert_eq!(store.model("lake").expect("model").tables.len(), 1);
    store.undo("lake", "you").expect("undone");
    assert_eq!(store.model("lake").expect("model").tables.len(), 2, "items is back");
    store.undo("lake", "you").expect("the add undone too");
    assert_eq!(store.model("lake").expect("model").tables.len(), 1);
    let kinds: Vec<String> = store.operations("lake").expect("log").into_iter().map(|o| o.kind).collect();
    assert_eq!(kinds, ["change", "link_rule", "enforce_rule", "change", "change", "undo", "undo"]);
}

#[test]
fn hard_means_hard_on_every_table_a_change_touches() {
    use schema_forge_core::DataType;
    use schema_forge_core::ops::{NewColumn, Op};
    use schema_forge_core::rules::{Enforce, Link, Scope};
    use schema_forge_store::Rules;
    let dir = tempfile::tempdir().expect("dir");
    let store = Store::open(&dir.path().join("store.redb")).expect("open");
    store.create_schema("lake", Target::Iceberg).expect("create");
    let col = |name: &str| NewColumn {
        name: name.into(),
        data_type: DataType::named("string"),
        nullable: true,
        default: None,
        comment: None,
    };
    let table = |name: &str| Op::AddTable {
        namespace: "shop".into(),
        name: name.into(),
        comment: None,
        columns: vec![col("id")],
        primary_key: vec![],
    };
    // No rules yet: anything goes.
    store
        .change(
            "lake",
            &[Op::AddNamespace { name: "shop".into(), parent: None, comment: None }, table("orders"), table("items")],
            false,
            "agent",
        )
        .expect("built");
    // Soft first: the breaks are shown, nothing is refused.
    let docs = Link {
        rule: "docs.table".into(),
        at: Scope::Schema,
        off: false,
        locked: false,
        reason: None,
        enforce: Some(Enforce::Soft),
    };
    store.link_rule(Rules::Schema("lake"), docs, "you").expect("soft");
    store
        .change("lake", &[Op::RenameTable { table: "items".into(), name: "lines".into() }], false, "agent")
        .expect("soft lets it through");
    // Then hard: touching a table that breaks it is refused until the change fixes it.
    store.set_enforce(Rules::Schema("lake"), "docs.table", &Scope::Schema, Enforce::Hard, "you").expect("hard");
    let rename = [Op::RenameTable { table: "lines".into(), name: "items".into() }];
    let Err(Error::Hard { message: why, .. }) = store.change("lake", &rename, false, "agent") else {
        panic!("refused")
    };
    assert!(why.contains("docs.table") && why.contains("has no description"), "{why}");
    let fixed = [
        Op::SetTableComment { table: "lines".into(), comment: Some("one line of an order".into()) },
        rename[0].clone(),
    ];
    store.change("lake", &fixed, false, "agent").expect("fixed in the same change, it lands");
    // A table the change does not touch does not block it.
    store
        .change("lake", &[Op::AddColumn { table: "items".into(), column: col("sku"), after: None }], false, "agent")
        .expect("items keeps its rules");
}

#[test]
fn a_turn_groups_the_agents_changes_to_accept_or_reject_whole() {
    use schema_forge_core::DataType;
    use schema_forge_core::ops::{NewColumn, Op};
    use schema_forge_store::TurnStatus;
    let dir = tempfile::tempdir().expect("dir");
    let store = Store::open(&dir.path().join("store.redb")).expect("open");
    store.create_schema("lake", Target::Iceberg).expect("create");
    let col = |name: &str| NewColumn {
        name: name.into(),
        data_type: DataType::named("string"),
        nullable: true,
        default: None,
        comment: None,
    };
    let table = |name: &str| Op::AddTable {
        namespace: "shop".into(),
        name: name.into(),
        comment: None,
        columns: vec![col("id")],
        primary_key: vec![],
    };
    let one = store.start_turn("lake", "make a shop", "agent").expect("turn");
    store
        .change_in(
            "lake",
            &[Op::AddNamespace { name: "shop".into(), parent: None, comment: None }, table("orders")],
            false,
            "agent",
            Some(one.id),
        )
        .expect("one");
    store.accept_turn("lake", one.id, "you").expect("accepted");
    assert!(
        store.change_in("lake", &[table("late")], false, "agent", Some(one.id)).is_err(),
        "a decided turn takes no more changes"
    );

    let two = store.start_turn("lake", "add items and refunds", "agent").expect("turn");
    store.change_in("lake", &[table("items")], false, "agent", Some(two.id)).expect("items");
    store
        .change_in(
            "lake",
            &[Op::AddColumn { table: "items".into(), column: col("sku"), after: None }],
            false,
            "agent",
            Some(two.id),
        )
        .expect("sku");
    store.change_in("lake", &[table("refunds")], false, "agent", Some(two.id)).expect("refunds");
    assert_eq!(store.turns("lake").expect("turns")[1].changes.len(), 3);
    let rejected = store.reject_turn("lake", two.id, "you").expect("rejected");
    assert_eq!(rejected.status, TurnStatus::Rejected);
    let names: Vec<String> = store.model("lake").expect("model").tables.into_iter().map(|t| t.name).collect();
    assert_eq!(names, ["orders"], "the whole turn is taken back");

    // Something it touched changed since: refused, and nothing taken back.
    let three = store.start_turn("lake", "notes", "agent").expect("turn");
    store.change_in("lake", &[table("notes")], false, "agent", Some(three.id)).expect("notes");
    store
        .change("lake", &[Op::SetTableComment { table: "notes".into(), comment: Some("by you".into()) }], false, "you")
        .expect("you");
    assert!(matches!(store.reject_turn("lake", three.id, "you"), Err(Error::Refused(_))));
    assert_eq!(store.model("lake").expect("model").tables.len(), 2, "notes stays");
}

#[test]
fn approvals_take_their_own_ids_and_switch_off_what_they_contradict() {
    use schema_forge_core::rules::custom::{ColumnMust, Pattern, Sentence};
    use schema_forge_core::rules::review::{Proposed, Status};
    use schema_forge_core::rules::{Enforce, Link, Scope};
    use schema_forge_store::Rules;
    let dir = tempfile::tempdir().expect("dir");
    let store = std::sync::Arc::new(Store::open(&dir.path().join("store.redb")).expect("open"));
    store.create_schema("lake", Target::Iceberg).expect("create");
    let model: Schema = serde_json::from_value(serde_json::json!({
        "format": 1,
        "target": "iceberg",
        "namespaces": [{ "id": "n_a", "name": "a" }],
        "tables": [{ "id": "t_x", "namespace": "n_a", "name": "x", "columns": [
            { "id": "c_x_created_at", "name": "created_at", "type": { "name": "string" }, "nullable": true }
        ] }]
    }))
    .expect("a schema");
    store.replace_model("lake", &model, "import", "import").expect("save");
    let types =
        Link { rule: "types".into(), at: Scope::Schema, off: false, locked: false, reason: None, enforce: None };
    store.link_rule(Rules::Schema("lake"), types, "you").expect("types");
    let has = |c: &str| Proposed::New {
        sentence: Sentence::HasColumn { column: c.into(), required: false, types: vec![] },
        targets: vec![],
    };
    let strings = Proposed::New {
        sentence: Sentence::Columns {
            name: Pattern::EndsWith("_at".into()),
            must: ColumnMust::OfType(vec!["string".into()]),
        },
        targets: vec![],
    };
    let items = vec![
        (has("a"), Scope::Schema, Enforce::Soft, "seen".into()),
        (has("b"), Scope::Schema, Enforce::Soft, "seen".into()),
        (has("c"), Scope::Schema, Enforce::Soft, "seen".into()),
        (strings, Scope::Schema, Enforce::Soft, "times arrive as text".into()),
    ];
    store.propose("lake", items, "agent").expect("proposed");
    // Approved at once, as "Approve the verified" does: each gets its own rule.
    let handles: Vec<_> = (1..=3)
        .map(|id| {
            let s = std::sync::Arc::clone(&store);
            std::thread::spawn(move || s.decide("lake", id, true, "you").expect("approved").rule)
        })
        .collect();
    let mut ids: Vec<String> = handles.into_iter().filter_map(|h| h.join().expect("joined")).collect();
    ids.sort();
    assert_eq!(ids, ["custom.1", "custom.2", "custom.3"]);
    assert_eq!(store.custom_rules().expect("custom").len(), 3);
    // Times kept as text contradict types.time: approving switches it off here, in the same change.
    let p = store.decide("lake", 4, true, "you").expect("approved with the conflict settled");
    assert_eq!(p.status, Status::Approved);
    let set = store.rules("lake").expect("rules");
    let off = set.links.iter().find(|l| l.rule == "types.time").expect("types.time switched off");
    assert!(off.off && off.reason.as_deref().is_some_and(|r| r.contains("proposal #4")));
    let custom = store.custom_rules().expect("custom");
    assert_eq!(
        custom.last().map(|c| c.targets.as_slice()),
        Some([Target::Iceberg].as_slice()),
        "a type rule holds on its target"
    );
    let log = store.operations("lake").expect("log");
    let last = log.last().expect("an operation");
    assert_eq!(last.kind, "approve_rule");
    assert_eq!(last.change["switched_off"], serde_json::json!(["types.time"]));
    assert_eq!(last.change["rule"], "custom.4");
}

#[test]
fn changes_at_the_same_time_never_overwrite_each_other_and_undo_never_breaks_the_schema() {
    use schema_forge_core::DataType;
    use schema_forge_core::ops::{NewColumn, Op};
    let dir = tempfile::tempdir().expect("dir");
    let store = std::sync::Arc::new(Store::open(&dir.path().join("store.redb")).expect("open"));
    store.create_schema("lake", Target::Postgres).expect("create");
    let col = |name: &str| NewColumn {
        name: name.into(),
        data_type: DataType::named("bigint"),
        nullable: true,
        default: None,
        comment: None,
    };
    let table = |name: &str| Op::AddTable {
        namespace: "public".into(),
        name: name.into(),
        comment: None,
        columns: vec![col("id")],
        primary_key: vec!["id".into()],
    };
    store
        .change(
            "lake",
            &[Op::AddNamespace { name: "public".into(), parent: None, comment: None }, table("customers")],
            false,
            "you",
        )
        .expect("base");
    // Ten columns added at once, from ten threads, to the same table: every one lands.
    let handles: Vec<_> = (0..10)
        .map(|i| {
            let s = std::sync::Arc::clone(&store);
            std::thread::spawn(move || {
                s.change(
                    "lake",
                    &[Op::AddColumn { table: "customers".into(), column: col(&format!("c{i}")), after: None }],
                    false,
                    "agent",
                )
                .expect("added")
            })
        })
        .collect();
    for h in handles {
        h.join().expect("joined");
    }
    assert_eq!(store.model("lake").expect("model").tables[0].columns.len(), 11, "no change overwrote another");
    // A table, then a relationship onto it made by an import: undoing the table would leave the link dangling.
    store.change("lake", &[table("orders")], false, "you").expect("orders");
    let mut m = store.model("lake").expect("model");
    let (c, o) = (m.tables[0].clone(), m.tables[1].clone());
    m.relationships.push(schema_forge_core::Relationship {
        id: schema_forge_core::Id::try_from("r_orders_customers".to_string()).expect("id"),
        name: None,
        from: schema_forge_core::Ends { table: c.id.clone(), columns: vec![c.columns[1].id.clone()] },
        to: schema_forge_core::Ends { table: o.id.clone(), columns: vec![o.columns[0].id.clone()] },
        enforced: true,
        on_delete: None,
        on_update: None,
        deferrable: None,
        match_kind: None,
    });
    store.replace_model("lake", &m, "import", "import").expect("relationship");
    assert!(matches!(store.undo("lake", "you"), Err(Error::Refused(_))), "the relationship needs orders");
    assert_eq!(store.model("lake").expect("model").tables.len(), 2, "nothing was undone");
}

#[test]
fn a_turn_opens_only_when_its_change_lands_and_a_reject_never_breaks_the_schema() {
    use schema_forge_core::DataType;
    use schema_forge_core::ops::{NewColumn, Op};
    use schema_forge_store::TurnTo;
    let dir = tempfile::tempdir().expect("dir");
    let store = Store::open(&dir.path().join("store.redb")).expect("open");
    store.create_schema("lake", Target::Postgres).expect("create");
    let col = |name: &str| NewColumn {
        name: name.into(),
        data_type: DataType::named("bigint"),
        nullable: false,
        default: None,
        comment: None,
    };
    let table = |name: &str| Op::AddTable {
        namespace: "public".into(),
        name: name.into(),
        comment: None,
        columns: vec![col("id"), col("ref")],
        primary_key: vec!["id".into()],
    };
    store
        .change(
            "lake",
            &[Op::AddNamespace { name: "public".into(), parent: None, comment: None }, table("orders")],
            false,
            "you",
        )
        .expect("base");
    // Refused (a drop without a yes): no turn is left behind.
    let refused = store.change_to(
        "lake",
        &[Op::DropTable { table: "orders".into() }],
        false,
        "agent",
        TurnTo::New("drop it".into()),
    );
    assert!(refused.is_err());
    assert!(store.turns("lake").expect("turns").is_empty(), "no empty turn");
    let made =
        store.change_to("lake", &[table("items")], false, "agent", TurnTo::New("add items".into())).expect("lands");
    let n = made.turn.expect("a turn");
    assert_eq!(store.turns("lake").expect("turns").len(), 1);
    // A link onto items made by hand, outside the turn: rejecting the turn would leave it dangling.
    store
        .change(
            "lake",
            &[Op::Relate {
                from: "orders".into(),
                columns: vec!["ref".into()],
                to: "items".into(),
                to_columns: vec!["id".into()],
                name: None,
            }],
            false,
            "you",
        )
        .expect("related");
    assert!(matches!(store.reject_turn("lake", n, "you"), Err(Error::Refused(_))), "the relationship needs items");
    assert_eq!(store.model("lake").expect("model").tables.len(), 2, "nothing was taken back");
    // Undone one at a time, a change leaves the turn's list.
    let second = store
        .change_to(
            "lake",
            &[Op::SetTableComment { table: "items".into(), comment: Some("x".into()) }],
            false,
            "agent",
            TurnTo::Open(n),
        )
        .expect("second");
    assert_eq!(second.turn, Some(n));
    store.undo("lake", "you").expect("undo the comment");
    let listed = store.turns_with_changes("lake").expect("listed");
    assert_eq!(listed[0].1.len(), 1, "only the live change is listed");
}
