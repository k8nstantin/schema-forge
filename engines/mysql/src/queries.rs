//! What a query reads: the tables and views it names, parsed with `sqlparser`'s MySQL dialect. The names a query gives
//! its own common table expressions are not tables.

use std::ops::ControlFlow;

use sqlparser::ast::{ObjectName, ObjectNamePart, Query, Visit, Visitor};
use sqlparser::dialect::MySqlDialect;
use sqlparser::parser::Parser;

/// The tables and views `query` reads, as the name parts written, in the order first named.
///
/// # Errors
/// When `query` is not one query in MySQL's SQL.
pub fn reads(query: &str) -> Result<Vec<Vec<String>>, String> {
    let statements = Parser::parse_sql(&MySqlDialect {}, query).map_err(|e| e.to_string())?;
    if statements.len() != 1 {
        return Err(format!("{} statements, not one query", statements.len()));
    }
    let mut v = Reads::default();
    let _ = statements.visit(&mut v);
    let ctes = v.ctes;
    Ok(v.names.into_iter().filter(|n| !(n.len() == 1 && ctes.iter().any(|c| c.eq_ignore_ascii_case(&n[0])))).collect())
}

#[derive(Default)]
struct Reads {
    names: Vec<Vec<String>>,
    ctes: Vec<String>,
}

impl Visitor for Reads {
    type Break = ();

    fn pre_visit_query(&mut self, query: &Query) -> ControlFlow<()> {
        if let Some(with) = &query.with {
            self.ctes.extend(with.cte_tables.iter().map(|c| c.alias.name.value.clone()));
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_relation(&mut self, relation: &ObjectName) -> ControlFlow<()> {
        let parts: Vec<String> = relation
            .0
            .iter()
            .map(|p| match p {
                ObjectNamePart::Identifier(i) => i.value.clone(),
                ObjectNamePart::Function(f) => f.name.value.clone(),
            })
            .collect();
        if !self.names.contains(&parts) {
            self.names.push(parts);
        }
        ControlFlow::Continue(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_query_reads_the_tables_it_names() {
        let q = "select `c`.`name` AS `name`,count(`o`.`order_id`) AS `n` from (`customers` `c` left join `shop`.`orders` \
                 `o` on((`o`.`customer_id` = `c`.`id`))) group by `c`.`name`";
        assert_eq!(reads(q), Ok(vec![vec!["customers".to_string()], vec!["shop".to_string(), "orders".to_string()]]));
        let cte = "with recent as (select * from orders) select * from recent join customers using (id)";
        assert_eq!(reads(cte), Ok(vec![vec!["orders".to_string()], vec!["customers".to_string()]]));
        assert!(reads("select 1; select 2").is_err());
    }
}
