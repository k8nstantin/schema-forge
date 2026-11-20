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

/// The tables and views a view's definition reads, each as the name parts written (`shop.orders` is
/// `["shop", "orders"]`), in `target`'s dialect: Spark SQL on Iceberg, PostgreSQL's own.
///
/// # Errors
/// When the definition does not parse as one query in that dialect.
pub fn view_relations(target: Target, definition: &str) -> Result<Vec<Vec<String>>, String> {
    let parsed = match target {
        Target::Iceberg => sqlparser::parser::Parser::parse_sql(&sqlparser::dialect::DatabricksDialect {}, definition),
        Target::Postgres => sqlparser::parser::Parser::parse_sql(&sqlparser::dialect::PostgreSqlDialect {}, definition),
        Target::Mysql => sqlparser::parser::Parser::parse_sql(&sqlparser::dialect::MySqlDialect {}, definition),
    }
    .map_err(|e| format!("the definition does not parse: {e}"))?;
    if parsed.len() != 1 || !matches!(parsed[0], sqlparser::ast::Statement::Query(_)) {
        return Err("a view's definition is one query (SELECT …)".to_string());
    }
    let fold = target == Target::Postgres;
    let mut names: Vec<Vec<String>> = Vec::new();
    let _ = sqlparser::ast::visit_relations(&parsed, |name| {
        let parts: Vec<String> = name
            .0
            .iter()
            .filter_map(|p| p.as_ident())
            .map(|i| if fold && i.quote_style.is_none() { i.value.to_lowercase() } else { i.value.clone() })
            .collect();
        if !names.contains(&parts) {
            names.push(parts);
        }
        std::ops::ControlFlow::<()>::Continue(())
    });
    Ok(names)
}

#[cfg(test)]
mod view_relations_tests {
    use super::*;

    #[test]
    fn a_view_reads_what_its_query_names() {
        let r = view_relations(
            Target::Iceberg,
            "SELECT o.id, c.email FROM shop.orders o JOIN customers c ON o.customer_id = c.id",
        );
        assert_eq!(r, Ok(vec![vec!["shop".to_string(), "orders".to_string()], vec!["customers".to_string()]]));
        assert_eq!(
            view_relations(Target::Postgres, "SELECT * FROM Public.Orders"),
            Ok(vec![vec!["public".to_string(), "orders".to_string()]])
        );
        assert!(view_relations(Target::Iceberg, "SELEC nonsense").is_err());
        assert!(view_relations(Target::Iceberg, "DROP TABLE orders").is_err(), "a view is a query");
    }
}

#[cfg(test)]
mod view_fields_tests {
    use super::*;

    #[test]
    fn a_views_fields_are_written_and_read_back() {
        let sql = "CREATE TABLE `shop`.`orders` (`id` STRING NOT NULL, `total` BIGINT) USING iceberg;\n\nCREATE VIEW `shop`.`totals` (\n  `id`,\n  `total` COMMENT 'summed'\n)\nCOMMENT 'per order' AS\nSELECT id, total FROM shop.orders;\n";
        let first = iceberg::import(sql).expect("read");
        let v = &first.schema.views[0];
        assert_eq!(
            v.columns.iter().map(|c| (c.name.as_str(), c.comment.as_deref())).collect::<Vec<_>>(),
            [("id", None), ("total", Some("summed"))]
        );
        let again = iceberg::import(&iceberg::generate(&first.schema)).expect("read back");
        assert_eq!(again.schema.views, first.schema.views, "the fields survive a round trip");
    }
}
