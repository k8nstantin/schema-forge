//! The conformance kit on the MySQL engine: every real dump read, and the canonical samples written back exactly.

use std::path::{Path, PathBuf};

use schema_forge_engine::kit::{QuerySample, Sample, Samples, assert_conforms};
use schema_forge_mysql::Mysql;

fn sample(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/samples").join(name)
}

#[test]
fn the_mysql_engine_conforms() {
    const VERSIONS: [&str; 4] = ["8.0", "8.4", "9.7", "26.10"];
    // Dumps of the shop by each version's own mysqldump, schema only and whole, and dumps of what this engine wrote,
    // loaded into that version.
    let dumps: Vec<PathBuf> = VERSIONS
        .iter()
        .flat_map(|v| ["schema", "full", "roundtrip"].map(|kind| sample(&format!("shop/{kind}{v}.sql"))))
        .collect();
    // The shop as this engine writes it for each version.
    let mut written: Vec<PathBuf> = VERSIONS.iter().map(|v| sample(&format!("shop/shop{v}.sql"))).collect();
    // Hand-written DDL, and the same as this engine writes it.
    let mut dumps = dumps;
    for v in ["8.4", "9.7"] {
        dumps.push(sample(&format!("handwritten/handwritten{v}.sql")));
        written.push(sample(&format!("handwritten/written{v}.sql")));
    }
    let mut files: Vec<Sample<'_>> = dumps.iter().map(|p| Sample::read_only(p)).collect();
    files.extend(written.iter().map(|p| Sample::written_back(p)));
    let queries = [
        QuerySample::new(
            "select `o`.`id` from `shop`.`orders` `o` join customers c on c.id = o.customer_id",
            &[&["shop", "orders"], &["customers"]],
        ),
        QuerySample::new("with recent as (select * from orders) select * from recent", &[&["orders"]]),
    ];
    assert_conforms(&Mysql::new(), &Samples::new(&files, &queries));
}
