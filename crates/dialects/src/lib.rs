//! Reading and writing the targets' own SQL: PostgreSQL dumps and Iceberg DDL in, the same formats out.

pub mod cursor;
pub mod iceberg;
pub mod postgres;
pub mod report;
pub mod split;

pub use report::{Imported, Report};

use schema_forge_core::{DataType, Target};

/// A type written as text for `target`: the model's names (`long`, `string`, `timestamptz`, `timestamp`,
/// `decimal(18,2)`, `list<string>`, `map<string, long>`, `struct<a: int>`) on Iceberg, the type as PostgreSQL writes it
/// (`varchar(200)`, `numeric(12,2)`, `timestamptz`, `text[]`) on PostgreSQL.
///
/// # Errors
/// When the text is not a type the model describes for `target`.
pub fn parse_type(target: Target, text: &str) -> Result<DataType, String> {
    let text = text.trim();
    let bad = || {
        format!(
            "`{text}` is not a {} type",
            match target {
                Target::Mysql => "MySQL",
                Target::Postgres => "PostgreSQL",
                Target::Iceberg => "Iceberg",
            }
        )
    };
    match target {
        Target::Iceberg => {
            // The model's names, in the Spark SQL the reader takes: there TIMESTAMP is the zoned one.
            // Only words in a type's place are swapped: a struct field's name (a word before `:`) stays as written.
            let runs = words(text);
            let named = |i: usize| {
                runs[i + 1..].iter().find(|r| !r.trim().is_empty()).is_some_and(|r| r.trim_start().starts_with(':'))
            };
            let spark: String = runs
                .iter()
                .enumerate()
                .map(|(i, w)| match w.to_ascii_lowercase().as_str() {
                    _ if named(i) => w.clone(),
                    "list" => "array".to_string(),
                    "timestamptz" => "timestamp_ltz".to_string(),
                    "timestamp" => "timestamp_ntz".to_string(),
                    _ => w.clone(),
                })
                .collect();
            let st = split::split(&sqlparser::dialect::DatabricksDialect {}, &spark).map_err(|_| bad())?;
            let first = st.statements.first().ok_or_else(bad)?;
            iceberg::types::read(&first.tokens).ok_or_else(bad)
        }
        Target::Postgres => {
            let st = split::split(&sqlparser::dialect::PostgreSqlDialect {}, text).map_err(|_| bad())?;
            let first = st.statements.first().ok_or_else(bad)?;
            let cur = cursor::Cur::new(first, cursor::Case::FoldLower);
            let t = postgres::types::read(&cur, 0, first.tokens.len(), &std::collections::HashMap::new());
            if t.is_verbatim() { Err(bad()) } else { Ok(t) }
        }
        Target::Mysql => Err("MySQL types come with the MySQL reader".to_string()),
    }
}

/// `text` cut into runs of word characters and the rest, so words can be swapped whole.
fn words(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut word = false;
    for ch in text.chars() {
        let w = ch.is_ascii_alphanumeric() || ch == '_';
        if out.is_empty() || w != word {
            out.push(String::new());
            word = w;
        }
        out.last_mut().expect("a run").push(ch);
    }
    out
}

/// The views, each after the views it reads (a cycle, which the model refuses, keeps the rest in model order).
pub(crate) fn views_in_order(schema: &schema_forge_core::Schema) -> Vec<&schema_forge_core::View> {
    let mut done: std::collections::HashSet<&schema_forge_core::Id> = std::collections::HashSet::new();
    let mut out = Vec::new();
    let mut left: Vec<&schema_forge_core::View> = schema.views.iter().collect();
    while !left.is_empty() {
        let before = left.len();
        left.retain(|v| {
            let ready = v.reads.iter().all(|r| done.contains(r) || !schema.views.iter().any(|x| &x.id == r));
            if ready {
                done.insert(&v.id);
                out.push(*v);
            }
            !ready
        });
        if left.len() == before {
            out.append(&mut left);
        }
    }
    out
}

#[cfg(test)]
mod parse_type_tests {
    use super::*;

    #[test]
    fn types_are_read_as_each_target_writes_them() {
        let t = |s| parse_type(Target::Iceberg, s).map(|t| t.name);
        assert_eq!(t("long").as_deref(), Ok("long"));
        assert_eq!(t("timestamptz").as_deref(), Ok("timestamptz"));
        assert_eq!(t("timestamp").as_deref(), Ok("timestamp"), "the model's timestamp has no zone");
        assert_eq!(t("list<string>").as_deref(), Ok("list"));
        assert_eq!(
            parse_type(Target::Iceberg, "decimal(18,2)").map(|t| (t.precision, t.scale)),
            Ok((Some(18), Some(2)))
        );
        assert!(parse_type(Target::Iceberg, "varchar2 nonsense").is_err());
        let st = parse_type(Target::Iceberg, "struct<timestamp: timestamp, list: list<string>>").expect("a struct");
        let names: Vec<&str> = st.fields.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, ["timestamp", "list"], "field names are kept as written");
        assert_eq!((st.fields[0].data_type.name.as_str(), st.fields[1].data_type.name.as_str()), ("timestamp", "list"));
        let p = parse_type(Target::Postgres, "timestamptz").expect("a type");
        assert!(p.name == "timestamp" && p.with_time_zone);
        assert_eq!(parse_type(Target::Postgres, "varchar(200)").map(|t| t.length), Ok(Some(200)));
        assert!(parse_type(Target::Postgres, "not a type at all").is_err());
    }
}
