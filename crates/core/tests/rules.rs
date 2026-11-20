//! Rules held to docs/rules.md: links flow down the hierarchy, the nearest wins, exceptions switch a rule or one
//! rule inside it off with a reason, a locked rule stays on, and each check finds what breaks it.

use schema_forge_core::rules::{self, Group, Link, RuleSet, Scope};
use schema_forge_core::{Id, Schema};
use serde_json::{Value, json};

fn id(s: &str) -> Id {
    Id::try_from(s.to_string()).expect("an id")
}

fn column(table: &str, name: &str, ty: &str, nullable: bool) -> Value {
    json!({ "id": format!("c_{table}_{}", name.to_lowercase()), "name": name, "type": { "name": ty }, "nullable": nullable })
}

/// A `shop` namespace of orders with a copied attribute and three phone slots; a `ledger` namespace in
/// camelCase with money in a double.
fn schema() -> Schema {
    serde_json::from_value(json!({
        "format": 1,
        "target": "iceberg",
        "namespaces": [{ "id": "n_shop", "name": "shop" }, { "id": "n_ledger", "name": "ledger" }],
        "tables": [
            { "id": "t_customers", "namespace": "n_shop", "name": "customers", "comment": "people who buy",
              "columns": [column("customers", "id", "string", false), column("customers", "name", "string", true),
                          column("customers", "phone1", "string", true), column("customers", "phone2", "string", true),
                          column("customers", "phone3", "string", true), column("customers", "created_at", "string", true)] },
            { "id": "t_orders", "namespace": "n_shop", "name": "orders",
              "columns": [column("orders", "id", "string", false), column("orders", "customer_id", "string", true),
                          column("orders", "customer_name", "string", true), column("orders", "placed_at", "timestamptz", true)],
              "options": { "iceberg": { "identifier_fields": ["c_orders_id"],
                "properties": { "write.delete.mode": "merge-on-read", "write.update.mode": "merge-on-read", "write.merge.mode": "merge-on-read" } } } },
            { "id": "t_entries", "namespace": "n_ledger", "name": "entries",
              "columns": [column("entries", "entryId", "long", true), column("entries", "amount", "double", true),
                          column("entries", "tags", "map", true)] }
        ]
    }))
    .expect("a schema")
}

fn link(rule: &str, at: Scope) -> Link {
    Link { rule: rule.to_string(), at, off: false, locked: false, reason: None }
}

fn off(rule: &str, at: Scope, reason: &str) -> Link {
    Link { rule: rule.to_string(), at, off: true, locked: false, reason: Some(reason.to_string()) }
}

fn ns(n: &str) -> Scope {
    Scope::Namespace { namespace: id(n) }
}

fn table(t: &str) -> Scope {
    Scope::Table { table: id(t) }
}

fn applied(r: &rules::Report, t: &str) -> Vec<String> {
    r.tables[&id(t)].applied.iter().map(|a| a.rule.clone()).collect()
}

fn found(r: &rules::Report, rule: &str) -> Vec<String> {
    r.findings.iter().filter(|f| f.rule == rule).map(|f| f.message.clone()).collect()
}

#[test]
fn a_link_reaches_everything_under_its_level() {
    let set = RuleSet { links: vec![link("norm", Scope::Schema), link("pk", ns("n_ledger"))], groups: vec![] };
    let r = rules::check(&schema(), &[link("docs", Scope::Global)], &set);
    assert_eq!(applied(&r, "t_orders"), ["docs", "norm"]);
    assert_eq!(applied(&r, "t_entries"), ["docs", "norm", "pk"]);
    assert!(r.problems.is_empty(), "{:?}", r.problems);
}

#[test]
fn an_exception_switches_off_a_rule_or_one_rule_inside_it() {
    let set = RuleSet {
        links: vec![
            link("norm", Scope::Schema),
            off("norm", ns("n_ledger"), "a reporting layer"),
            off("norm.repeat", table("t_customers"), "the form has three phone slots"),
        ],
        groups: vec![],
    };
    let r = rules::check(&schema(), &[], &set);
    assert!(applied(&r, "t_entries").is_empty(), "switched off for the ledger");
    assert_eq!(r.tables[&id("t_entries")].excepted[0].reason, "a reporting layer");
    assert_eq!(applied(&r, "t_customers"), ["norm"], "the rest of normalization still applies");
    assert!(found(&r, "norm.repeat").is_empty(), "the phone slots are excepted");
    assert_eq!(found(&r, "norm.copies"), ["`customer_name` copies `customers.name`"]);
}

#[test]
fn the_nearest_link_wins_and_a_lower_link_brings_a_rule_back() {
    let set = RuleSet {
        links: vec![
            link("norm", Scope::Schema),
            off("norm", ns("n_shop"), "not here"),
            link("norm", table("t_orders")),
        ],
        groups: vec![],
    };
    let r = rules::check(&schema(), &[], &set);
    assert!(applied(&r, "t_customers").is_empty());
    assert_eq!(applied(&r, "t_orders"), ["norm"]);
}

#[test]
fn a_locked_rule_cannot_be_switched_off_below() {
    let cat = rules::catalog();
    let global = [Link { locked: true, ..link("pk", Scope::Global) }];
    let set = RuleSet::default();
    let refused = rules::admit(cat, &schema(), &global, &set, &off("pk.ident", ns("n_ledger"), "no upserts"));
    assert!(refused.unwrap_err().contains("locked"), "a rule inside a locked pack stays on");
    let no_reason = Link { reason: None, ..off("norm", Scope::Schema, "") };
    assert!(
        rules::admit(
            cat,
            &schema(),
            &[],
            &RuleSet { links: vec![link("norm", Scope::Global)], groups: vec![] },
            &no_reason
        )
        .is_err()
    );
    assert!(
        rules::admit(cat, &schema(), &[], &set, &off("norm", Scope::Schema, "x"))
            .unwrap_err()
            .contains("does not reach")
    );
    assert!(rules::admit(cat, &schema(), &[], &set, &link("nope", Scope::Schema)).is_err());
    assert!(rules::admit(cat, &schema(), &[], &set, &link("norm", table("t_missing"))).is_err());
    // An exception written to the store anyway is not honoured.
    let r = rules::check(&schema(), &global, &RuleSet { links: vec![off("pk", Scope::Schema, "x")], groups: vec![] });
    assert_eq!(applied(&r, "t_orders"), ["pk"]);
}

#[test]
fn a_group_cuts_across_namespaces() {
    let set = RuleSet {
        links: vec![link("cdc", Scope::Group { group: "streamed".to_string() })],
        groups: vec![Group { name: "streamed".to_string(), tables: vec![id("t_orders"), id("t_entries")] }],
    };
    let r = rules::check(&schema(), &[], &set);
    assert_eq!(applied(&r, "t_orders"), ["cdc"]);
    assert!(applied(&r, "t_customers").is_empty());
    assert_eq!(found(&r, "pk.ident"), ["`entries` declares no identifier fields"], "cdc holds the pk pack");
    assert_eq!(found(&r, "cdc.position").len(), 2);
    assert_eq!(
        found(&r, "mor.modes"),
        ["`entries` is not merge-on-read for write.delete.mode, write.update.mode, write.merge.mode"]
    );
}

#[test]
fn the_checks_find_what_breaks_them() {
    let set = RuleSet {
        links: vec![
            link("types", Scope::Schema),
            link("naming", Scope::Schema),
            link("docs", Scope::Schema),
            link("norm", Scope::Schema),
            link("compat.iceberg-mysql", Scope::Schema),
        ],
        groups: vec![],
    };
    let r = rules::check(&schema(), &[], &set);
    assert_eq!(found(&r, "types.time"), ["`created_at` holds a time as string: make it a timestamp"]);
    assert_eq!(found(&r, "types.money"), ["`amount` holds money as double: make it a decimal"]);
    assert_eq!(found(&r, "naming.case"), ["`entryId` is not snake_case"]);
    assert_eq!(found(&r, "docs.table"), ["`orders` has no description", "`entries` has no description"]);
    assert_eq!(
        found(&r, "norm.repeat"),
        ["3 columns of one kind (`phone1` … `phone3`): a child table holds any number of `phone`"]
    );
    assert!(
        found(&r, "compat.iceberg-mysql.lossy").iter().any(|m| m.starts_with("`tags` (map) becomes JSON in MySQL"))
    );
    assert!(found(&r, "compat.iceberg-mysql.lossy").iter().any(|m| m.starts_with("`placed_at` (timestamptz)")));
    assert_eq!(r.tallies["types"].breaks, 2, "a pack tallies its checks");
    assert_eq!(r.tallies["types.time"].checked, 2, "two time columns looked at");
}

#[test]
fn rules_are_optional_for_a_schema_or_a_group_even_when_locked() {
    let global = [Link { locked: true, ..link("pk", Scope::Global) }, link("docs", Scope::Global)];
    let none = |at: Scope| Link { rule: rules::ALL.to_string(), ..off("", at, "a scratch schema: no rules") };
    let set = RuleSet { links: vec![none(Scope::Schema)], groups: vec![] };
    let r = rules::check(&schema(), &global, &set);
    assert!(r.tables.values().all(|e| e.applied.is_empty()), "no rules at all here");
    assert!(r.findings.is_empty());
    let grouped = RuleSet {
        links: vec![none(Scope::Group { group: "raw".to_string() }), link("docs", table("t_orders"))],
        groups: vec![Group { name: "raw".to_string(), tables: vec![id("t_orders"), id("t_entries")] }],
    };
    let r = rules::check(&schema(), &global, &grouped);
    assert!(applied(&r, "t_entries").is_empty(), "the group uses no rules");
    assert_eq!(applied(&r, "t_orders"), ["docs"], "a link lower down still applies");
    assert_eq!(applied(&r, "t_customers"), ["pk", "docs"], "outside the group the rules hold");
    let cat = rules::catalog();
    assert!(rules::admit(cat, &schema(), &global, &RuleSet::default(), &none(Scope::Schema)).is_ok());
    assert!(rules::admit(cat, &schema(), &global, &RuleSet::default(), &link(rules::ALL, Scope::Schema)).is_err());
    assert!(
        rules::admit(cat, &schema(), &global, &RuleSet::default(), &Link { reason: None, ..none(Scope::Schema) })
            .is_err()
    );
}
