//! An add-on, written as any crate outside this one would write it: a MySQL-compatible system's own types join the
//! catalog, read and write back, and the engine still conforms.

use schema_forge_engine::kit::{QuerySample, Sample, Samples, assert_conforms};
use schema_forge_engine::{Engine, Input, TypeSpec};
use schema_forge_mysql::{AddOn, Family, Mysql, Params};

/// A made-up MySQL-compatible system with a `uuid` type and a sized `money(N)`.
struct Compatible;

const TYPES: &[Family] = &[
    Family::new("uuid", &[], Params::None, TypeSpec::new("uuid", "text", "A UUID, stored in 16 bytes", "uuid")),
    Family::new(
        "money",
        &[],
        Params::OneOr(2),
        TypeSpec::new("money(N)", "exact", "An amount with N decimals", "money(2)"),
    ),
];

impl AddOn for Compatible {
    fn name(&self) -> &'static str {
        "A compatible system's types"
    }

    fn types(&self) -> &[Family] {
        TYPES
    }
}

#[test]
fn an_add_on_adds_types_without_forking_the_engine() {
    let engine = Mysql::new().with(Compatible);
    assert_eq!(engine.add_ons().collect::<Vec<_>>(), ["A compatible system's types"]);
    let names: Vec<&str> = engine.types().catalog().iter().map(|t| t.name).collect();
    assert!(names.contains(&"uuid") && names.contains(&"money(N)") && names.contains(&"bigint"));
    assert_eq!(engine.types().parse("MONEY", "8.4").map(|p| p.text), Ok("money(2)".to_string()));
    assert!(Mysql::new().types().parse("uuid", "8.4").is_err(), "MySQL alone has no uuid");

    let dir = std::env::temp_dir().join(format!("schema-forge-mysql-addon-{}", std::process::id()));
    std::fs::create_dir(&dir).expect("a folder of its own");
    let file = dir.join("ledger.sql");
    std::fs::write(&file, "CREATE TABLE `ledger` (`id` uuid NOT NULL, `amount` money(4), PRIMARY KEY (`id`));\n")
        .expect("written");
    let imported = engine.read().expect("reads").read(&Input::open(&file).expect("the file")).expect("it reads");
    assert!(imported.report.not_understood.is_empty(), "{:?}", imported.report.not_understood);
    let written = engine.write().expect("writes").schema(&imported.schema).expect("it writes");
    assert!(written.contains("`id` uuid NOT NULL") && written.contains("`amount` money(4)"), "{written}");
    let written_path = dir.join("written.sql");
    std::fs::write(&written_path, &written).expect("written");
    let files = [Sample::read_only(&file), Sample::written_back(&written_path)];
    let queries = [QuerySample::new("select 1 from t", &[&["t"]])];
    assert_conforms(&engine, &Samples::new(&files, &queries));
    std::fs::remove_dir_all(&dir).expect("removed");
}
