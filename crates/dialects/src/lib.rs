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
            let spark: String = words(text)
                .into_iter()
                .map(|w| match w.to_ascii_lowercase().as_str() {
                    "list" => "array".to_string(),
                    "timestamptz" => "timestamp_ltz".to_string(),
                    "timestamp" => "timestamp_ntz".to_string(),
                    _ => w,
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
        let p = parse_type(Target::Postgres, "timestamptz").expect("a type");
        assert!(p.name == "timestamp" && p.with_time_zone);
        assert_eq!(parse_type(Target::Postgres, "varchar(200)").map(|t| t.length), Ok(Some(200)));
        assert!(parse_type(Target::Postgres, "not a type at all").is_err());
    }
}
