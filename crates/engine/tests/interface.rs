//! The interface, the registry and the conformance kit, on the made-up `example` engine.

mod example;

use std::path::Path;

use example::{Broken, Example};
use schema_forge_engine::kit::{self, QuerySample, Sample, Samples};
use schema_forge_engine::{Engine, Offered, Registry, TypeError, Unread};
use schema_forge_model::Schema;

const SHOP: &str = "tests/samples/shop.example";

fn shop() -> &'static Path {
    Path::new(SHOP)
}

fn files() -> [Sample<'static>; 1] {
    [Sample::written_back(shop())]
}

const QUERIES: &[QuerySample<'static>] = &[QuerySample::new(
    "select o.total, c.name from sales.orders o join sales.customers c on o.customer = c.id",
    &[&["sales", "orders"], &["sales", "customers"]],
)];

/// What `example` is checked on: its shop, written back, and a query.
fn check(engine: &Example) -> Vec<String> {
    let files = files();
    kit::check(engine, &Samples::new(&files, QUERIES))
}

#[test]
fn a_conforming_engine_passes_the_kit() {
    let files = files();
    kit::assert_conforms(&Example::new(), &Samples::new(&files, QUERIES));
}

/// The kit's findings for a broken copy of the engine.
fn findings(broken: Broken) -> Vec<String> {
    check(&Example::broken(broken))
}

fn has(findings: &[String], text: &str) -> bool {
    findings.iter().any(|f| f.contains(text))
}

#[test]
fn the_kit_finds_a_type_listed_twice() {
    let f = findings(Broken::TypeTwice);
    assert!(has(&f, "the type `int` is listed twice"), "{f:?}");
}

#[test]
fn the_kit_finds_a_feature_of_a_version_the_engine_does_not_have() {
    let f = findings(Broken::SinceNoVersion);
    assert!(has(&f, "the type `wide` names the version `9`, which is not one of its versions"), "{f:?}");
}

#[test]
fn the_kit_finds_a_type_read_in_a_version_without_it() {
    assert_eq!(findings(Broken::VersionIgnored), ["`wide` reads in version `1`, which does not have it"]);
}

#[test]
fn the_kit_finds_a_type_refused_without_saying_it_is_the_version() {
    assert_eq!(
        findings(Broken::VersionUnsaid),
        [
            "`wide` in version `1`, which does not have it, should be refused as not in the version, not: `wide` is not a type"
        ]
    );
}

#[test]
fn the_kit_finds_an_example_not_written_as_the_engine_writes_it() {
    let f = findings(Broken::ExampleUnwritten);
    assert!(has(&f, "the example `DECIMAL( 10 , 2 )` of `decimal(P,S)` is written `decimal(10,2)`"), "{f:?}");
}

#[test]
fn the_kit_finds_a_report_that_does_not_add_up() {
    let f = findings(Broken::ReportShort);
    assert!(has(&f, "the report does not add up: 12 read, 9 modelled, 0 kept, 0 data"), "{f:?}");
    assert!(has(&f, "the report lists 3 things not understood, but kept only 0"), "{f:?}");
}

#[test]
fn the_kit_finds_a_writer_that_loses_something() {
    let f = findings(Broken::WriterLoses);
    assert!(
        has(
            &f,
            "written back, it is not the sample: its line `-- the shop's tables` is written `table sales customers`"
        ),
        "{f:?}"
    );
    assert!(has(&f, "written and read back, it differs"), "{f:?}");
}

#[test]
fn the_kit_finds_kept_text_written_out_of_its_place() {
    let f = findings(Broken::KeptToEnd);
    assert!(has(&f, "written back, it is not the sample"), "{f:?}");
}

#[test]
fn the_kit_finds_a_type_that_names_the_wrong_version() {
    assert_eq!(findings(Broken::WrongSince), ["`wide` in version `1` says it came in version 1, not version 2"]);
}

#[test]
fn the_kit_finds_a_sample_to_write_back_with_no_writer() {
    let f = findings(Broken::NoWriter);
    assert_eq!(f, ["a sample is to be written back, but the engine writes nothing"]);
}

#[test]
fn the_kit_finds_a_report_that_does_not_say_what_it_counts() {
    let f = findings(Broken::NoUnit);
    assert!(has(&f, "the report does not say what it counts (its unit)"), "{f:?}");
}

#[test]
fn the_kit_finds_a_writer_no_sample_exercises() {
    let files = [Sample::read_only(shop())];
    assert_eq!(
        kit::check(&Example::new(), &Samples::new(&files, QUERIES)),
        ["it writes, but no sample is in the form it writes (`Sample::written_back`)"]
    );
}

#[test]
fn the_kit_finds_objects_without_a_definition() {
    let f = findings(Broken::NoDefinitions);
    assert!(has(&f, "`customers` has no definition") && has(&f, "`orders` has no definition"), "{f:?}");
}

#[test]
fn the_kit_finds_queries_read_wrong() {
    let f = findings(Broken::QueriesBlind);
    assert_eq!(f.len(), 1, "{f:?}");
    assert!(f[0].ends_with("reads [], not [[\"sales\", \"orders\"], [\"sales\", \"customers\"]]"), "{f:?}");
}

#[test]
fn the_kit_finds_a_default_version_that_is_not_one() {
    assert_eq!(findings(Broken::DefaultNoVersion), ["its default version `0` is not one of its versions"]);
}

#[test]
fn the_kit_finds_a_trigger_on_a_table_that_is_not_there() {
    let f = findings(Broken::TriggerOnNothing);
    assert!(has(&f, "`orders_touch`: it is a trigger on o_nowhere, which is not in the schema"), "{f:?}");
}

#[test]
fn a_trigger_is_an_object_on_its_table() {
    let e = Example::new();
    let registry = Registry::new().with(Example::new());
    let (_, input) = registry.reader_of(shop()).expect("a reader");
    let s = e.read().expect("it reads").read(&input).expect("it reads").schema;
    let touch = s.objects.iter().find(|o| o.kind == "trigger").expect("the trigger");
    let section: schema_forge_engine::sections::ObjectSection =
        schema_forge_engine::sections::read(&touch.engine).expect("in the layout");
    let t = section.trigger.expect("a trigger");
    assert_eq!(s.object(&t.table).map(|o| o.name.as_str()), Some("orders"));
    assert_eq!(t.body, "set new.placed = now()");
}

#[test]
fn the_kit_finds_an_object_of_a_kind_the_engine_does_not_declare() {
    let f = findings(Broken::UnknownKind);
    assert!(has(&f, "`customers` is a `sheet`, a kind the engine does not declare"), "{f:?}");
}

#[test]
fn the_kit_finds_a_slot_its_kind_does_not_use() {
    let f = findings(Broken::WrongSlot);
    assert!(has(&f, "`customers` is a `table`, which does not use the slot Query"), "{f:?}");
}

#[test]
fn the_kit_finds_an_option_declared_twice_for_the_same_kinds_and_versions() {
    let f = findings(Broken::OptionTwice);
    assert!(has(&f, "the option `fast` on Object is declared twice for the same kinds and versions"), "{f:?}");
}

#[test]
fn the_kit_finds_an_engine_that_does_not_map_its_types_to_arrow() {
    assert_eq!(findings(Broken::NoArrow), ["it does not map its types to Arrow (`Engine::portable`)"]);
}

#[test]
fn the_kit_finds_a_storage_format_later_than_the_engine_reads() {
    let f = findings(Broken::LaterFormat);
    assert!(has(&f, "it is stored in the engine's format 2, later than the 1 this engine reads"), "{f:?}");
}

#[test]
fn the_kit_finds_an_exact_arrow_mapping_that_does_not_come_back() {
    let f = findings(Broken::ArrowAstray);
    assert_eq!(f, ["`wide` maps to Arrow `LargeUtf8` exactly, but comes back as `text` in version `2`"]);
}

#[test]
fn the_kit_finds_a_section_off_the_layout() {
    let f = findings(Broken::OffLayout);
    assert!(has(&f, "the section of the schema does not follow the layout: unknown field `storage`"), "{f:?}");
}

#[test]
fn the_kit_finds_an_option_the_engine_does_not_declare() {
    let f = findings(Broken::UndeclaredOption);
    assert!(has(&f, "`orders` holds the option `quick`, which the engine does not declare there"), "{f:?}");
}

#[test]
fn an_engine_that_writes_and_does_not_read_can_conform() {
    assert_eq!(kit::check(&Example::broken(Broken::NoReader), &Samples::new(&[], QUERIES)), Vec::<String>::new());
}

#[test]
fn a_type_says_the_version_its_catalog_says_even_one_the_engine_lacks() {
    let f = findings(Broken::SinceNoVersion);
    assert!(has(&f, "`wide` in version `1` says it came in version 2, not version 9"), "{f:?}");
    assert!(!has(&f, "taken away"), "an unknown since is not a version that took it away: {f:?}");
}

#[test]
fn every_part_the_engine_has_needs_samples() {
    assert_eq!(
        kit::check(&Example::new(), &Samples::default()),
        [
            "it reads files, but no sample file is given",
            "it writes, but no sample is in the form it writes (`Sample::written_back`)",
            "it reads queries, but no sample query is given"
        ]
    );
}

#[test]
fn a_schema_is_offered_the_types_of_its_version() {
    let e = Example::new();
    let names = |v: &str| e.types_in(v).iter().map(|t| t.name).collect::<Vec<_>>();
    assert_eq!(names("1"), ["int", "decimal(P,S)", "text"]);
    assert_eq!(names("2"), ["int", "decimal(P,S)", "text", "wide"]);
    assert_eq!(e.types().parse(" DECIMAL( 12 , 4 ) ", "1").map(|p| p.text), Ok("decimal(12,4)".to_string()));
    let refused = e.types().parse("wide", "1").unwrap_err();
    assert_eq!(refused, TypeError::not_in_version("wide", Some("2")));
    assert_eq!(refused.to_string(), "`wide` came in version 2");
    assert!(matches!(e.types().parse("whole", "2"), Err(TypeError::NotAType(_))));
}

#[test]
fn reading_accounts_for_every_entry_and_writing_puts_kept_text_back_in_its_place() {
    let e = Example::new();
    let registry = Registry::new().with(Example::new());
    let (engine, input) = registry.reader_of(shop()).expect("a reader");
    assert_eq!(engine.id(), "example");
    let read = e.read().expect("it reads").read(&input).expect("it reads");
    let r = &read.report;
    assert_eq!((r.read, r.modelled, r.kept_total(), r.data), (12, 9, 3, 0));
    assert!(r.adds_up());
    assert_eq!(
        r.not_understood,
        [
            Unread::new("line 2", "-- the shop's tables"),
            Unread::new("line 7", "-- customers come from the web shop"),
            Unread::new("line 11", "-- totals are in the shop's currency"),
        ]
    );
    assert!(r.to_string().starts_with("12 non-blank lines read\n  modelled: 9\n  kept as written: 3\n"), "{r}");
    let s = &read.schema;
    assert_eq!((s.engine.id.as_str(), s.engine.version.as_str()), ("example", "2"));
    let write = e.write().expect("it writes");
    assert_eq!(
        write.schema(s).expect("it writes"),
        "example 2\n-- the shop's tables\ntable sales customers\ncolumn id int not-null\ncolumn name text null\n\
         -- customers come from the web shop\ntable sales orders fast\ncolumn id int not-null\n\
         -- totals are in the shop's currency\ncolumn total decimal(10,2) null\ncolumn note wide null\n\
         trigger sales orders_touch before insert on orders: set new.placed = now()\n"
    );
    let orders = &s.objects[1];
    assert_eq!(
        write.definition(s, &orders.id).expect("it writes").as_deref(),
        Some(
            "table sales orders fast\ncolumn id int not-null\ncolumn total decimal(10,2) null\ncolumn note wide null\n"
        )
    );
}

#[test]
fn the_registry_finds_the_schemas_engine() {
    let r = Registry::new().with(Example::new());
    assert_eq!(r.of(&Schema::new("example", "2")).map(Engine::id), Ok("example"));
    assert_eq!(
        r.of(&Schema::new("elsewhere", "1")).map(Engine::id),
        Err("the schema is for `elsewhere`, which this build has no engine for (it has example)".to_string())
    );
    assert_eq!(r.all().map(Engine::id).collect::<Vec<_>>(), ["example"]);
    assert!(r.get("elsewhere").is_none());
}

#[test]
#[should_panic(expected = "the engine `example` is registered twice")]
fn one_database_is_one_engine() {
    let _ = Registry::new().with(Example::new()).with(Example::new());
}

#[test]
fn the_reader_is_the_one_engine_that_recognises_the_input() {
    let r = Registry::new().with(Example::new());
    let err = r.reader_of(Path::new("tests/samples/other.txt")).map(|(e, _)| e.id()).unwrap_err();
    assert!(
        err.ends_with("no engine recognises it; say which engine it is for. Read here: Example (example files)"),
        "{err}"
    );
    let two = Registry::new().with(Example::new()).with(Example { id: "copy", broken: Broken::Nothing });
    let err = two.reader_of(shop()).map(|(e, _)| e.id()).unwrap_err();
    assert!(
        err.ends_with("more than one engine recognises it (Example, Example); say which engine it is for"),
        "{err}"
    );
    assert!(r.reader_of(Path::new("tests/samples/missing")).is_err());
    let folder = r.reader_of(Path::new("tests/samples")).map(|(e, _)| e.id()).unwrap_err();
    assert!(folder.contains("no engine recognises it"), "a folder this engine does not read: {folder}");
}

#[test]
fn the_kit_finds_machinery_left_out_of_the_report() {
    let files = [Sample::written_back(shop()), Sample::read_only(Path::new("tests/samples/machinery.example"))];
    kit::assert_conforms(&Example::new(), &Samples::new(&files, QUERIES));
    let f = kit::check(&Example::broken(Broken::MachineryUncounted), &Samples::new(&files, QUERIES));
    assert!(has(&f, "the report does not add up: 5 read, 3 modelled, 0 kept, 0 data, 0 machinery"), "{f:?}");
}

#[test]
fn the_kit_finds_connection_fields_that_are_wrong() {
    assert!(has(&findings(Broken::FieldTwice), "the connection field `host` is declared twice"));
    assert!(has(&findings(Broken::TwoSecrets), "a connection has more than one secret field"));
    assert!(has(
        &findings(Broken::DefaultNotAChoice),
        "the connection field `mode` defaults to `reckless`, which is not one of its choices"
    ));
    assert!(has(&findings(Broken::FieldUnlabelled), "the connection field `host` needs a key, a label and help"));
}

#[test]
fn a_secret_never_prints_and_a_profile_never_holds_one() {
    let engine = Example::new();
    let live = engine.live().expect("it has a live database");
    let profile = schema_forge_engine::live::Profile::new(std::collections::BTreeMap::from([(
        "host".to_string(),
        "db.example".to_string(),
    )]));
    let steps = live.test(&profile, Some(&schema_forge_engine::live::Secret::new("hunter2")));
    assert_eq!(steps.len(), 5);
    assert!(steps.iter().all(|s| !s.said.contains("hunter2")));
    assert!(live.read(&profile, None, &[]).is_err());
}
