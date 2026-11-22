//! Every real dump in the samples, read: every statement accounted for, nothing left not understood.

use std::path::{Path, PathBuf};

use schema_forge_engine::{Engine, Input};
use schema_forge_mysql::Mysql;

fn samples() -> Vec<PathBuf> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/samples/shop");
    let mut out: Vec<PathBuf> = std::fs::read_dir(&dir)
        .expect("the samples")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
                n.ends_with(".sql") && (n.starts_with("schema") || n.starts_with("full") || n.starts_with("roundtrip"))
            })
        })
        .collect();
    out.sort();
    out
}

#[test]
fn every_dump_reads_whole() {
    let engine = Mysql::new();
    let read = engine.read().expect("it reads");
    for path in samples() {
        let input = Input::open(&path).expect("the sample");
        assert!(read.recognises(&input), "{}", path.display());
        let imported = read.read(&input).expect("it reads");
        let r = &imported.report;
        println!("{}: version {}\n{r}", path.display(), imported.schema.engine.version);
        assert!(r.adds_up(), "{}", path.display());
        assert!(r.not_understood.is_empty(), "{}: {:?}", path.display(), r.not_understood);
    }
}

#[test]
#[ignore = "prints a dump's schema to look at"]
fn print_schema() {
    let engine = Mysql::new();
    let path = std::env::var("DUMP").expect("DUMP names a dump");
    let input = Input::open(Path::new(&path)).expect("the dump");
    println!("{}", engine.read().expect("reads").read(&input).expect("reads").schema.to_json());
}

#[test]
#[ignore = "prints a file's schema as this engine writes it"]
fn print_written() {
    let engine = Mysql::new();
    let path = std::env::var("DUMP").expect("DUMP names a file");
    let input = Input::open(Path::new(&path)).expect("the file");
    let schema = engine.read().expect("reads").read(&input).expect("reads").schema;
    print!("{}", engine.write().expect("writes").schema(&schema).expect("writes"));
}

/// A schema without its tables' `AUTO_INCREMENT` counters: the next number given is the rows' state, not the design.
fn without_counters(mut schema: schema_forge_model::Schema) -> schema_forge_model::Schema {
    use schema_forge_engine::sections::{ObjectSection, read, write};
    for o in &mut schema.objects {
        let mut s: ObjectSection = read(&o.engine).expect("a section");
        s.options.shift_remove("auto_increment");
        o.engine = write(&s);
    }
    schema
}

#[test]
fn what_this_engine_writes_loads_into_mysql_as_the_same_schema() {
    // roundtrip.sh loaded each canonical sample into MySQL and dumped it again; the original shop's dump and that dump
    // read as the same schema.
    let engine = Mysql::new();
    let read = engine.read().expect("it reads");
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/samples/shop");
    for v in ["8.0", "8.4", "9.7", "26.10"] {
        let schema = |name: String| {
            let imported = read.read(&Input::open(&dir.join(name)).expect("the sample")).expect("it reads");
            assert!(imported.report.not_understood.is_empty());
            without_counters(imported.schema)
        };
        let (original, again) = (schema(format!("schema{v}.sql")), schema(format!("roundtrip{v}.sql")));
        assert_eq!(original.to_json(), again.to_json(), "MySQL {v}");
    }
}

#[test]
fn every_dump_writes_and_reads_back_as_itself() {
    let engine = Mysql::new();
    let (read, write) = (engine.read().expect("it reads"), engine.write().expect("it writes"));
    let dir = std::env::temp_dir().join(format!("schema-forge-mysql-dumps-{}", std::process::id()));
    std::fs::create_dir(&dir).expect("a folder of its own");
    for path in samples() {
        let first = read.read(&Input::open(&path).expect("the dump")).expect("it reads").schema;
        let text = write.schema(&first).expect("it writes");
        let file = dir.join("written.sql");
        std::fs::write(&file, &text).expect("written");
        let again = read.read(&Input::open(&file).expect("written")).expect("it reads back");
        assert!(again.report.not_understood.is_empty(), "{}: {:?}", path.display(), again.report.not_understood);
        assert_eq!(first.to_json(), again.schema.to_json(), "{}", path.display());
    }
    std::fs::remove_dir_all(&dir).expect("removed");
}

fn handwritten(name: &str) -> schema_forge_engine::Imported {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/samples/handwritten").join(name);
    let input = Input::open(&path).expect("the sample");
    let read = Mysql::new();
    let read = read.read().expect("it reads");
    assert!(read.recognises(&input), "{name}");
    read.read(&input).expect("it reads")
}

#[test]
fn hand_written_ddl_reads_as_a_person_meant_it() {
    let i = handwritten("handwritten8.4.sql");
    let (s, r) = (&i.schema, &i.report);
    println!("{r}");
    assert!(r.adds_up());
    assert_eq!(s.engine.version, "8.4");
    assert_eq!(s.namespaces.iter().map(|n| n.name.as_str()).collect::<Vec<_>>(), ["default"]);
    let json = s.to_json();
    assert!(!json.contains("not-a-real-password"), "a credential is never kept");
    assert!(json.contains("ACCOUNT LOCK"), "an account is kept locked, without its password");
    assert_eq!(r.not_understood.len(), 1, "the ALTER TABLE, kept as written and reported: {:?}", r.not_understood);
    assert_eq!((r.kept.get("account"), r.kept.get("grant"), r.data), (Some(&1), Some(&1), 1));
    assert_eq!((r.kept.get("resource_group"), r.kept.get("server")), (Some(&1), Some(&1)));
    let widgets = s.objects.iter().find(|o| o.name == "widgets").expect("widgets");
    assert!(json.contains("REFERENCES inventory.warehouses (id)"), "a reference outside the schema, kept on its table");
    assert_eq!(s.links.len(), 1, "maker_id → makers");
    assert!(
        s.links[0].engine.get("enforced") == Some(&serde_json::json!(false)),
        "8.4 ignores a REFERENCES on a column"
    );
    assert_eq!(s.links[0].from.object, widgets.id);
    let cheap = s.objects.iter().filter(|o| o.name == "cheap").collect::<Vec<_>>();
    assert_eq!(cheap.len(), 1, "a view made again replaces the one before it");
    assert!(json.contains("SELECT id, sku, price FROM widgets"));
}

#[test]
fn libraries_javascript_and_loadable_functions_read() {
    let i = handwritten("handwritten9.7.sql");
    let (s, r) = (&i.schema, &i.report);
    println!("{r}");
    assert!(r.adds_up() && r.not_understood.is_empty(), "{:?}", r.not_understood);
    assert_eq!(s.engine.version, "9.7");
    let kinds: Vec<(&str, &str)> = s.objects.iter().map(|o| (o.kind.as_str(), o.name.as_str())).collect();
    assert_eq!(
        kinds,
        [
            ("library", "text_tools"),
            ("function", "slug"),
            ("loadable_function", "median"),
            ("table", "notes"),
            ("table", "tags"),
            ("procedure", "tag_note")
        ]
    );
    let json = s.to_json();
    assert!(json.contains("it's \\\"fine\\\"; really"), "a JavaScript body is kept exactly");
    assert_eq!(s.links.len(), 1);
    assert!(s.links[0].engine.get("enforced").is_none(), "from 9.0 a REFERENCES on a column is enforced");
}
