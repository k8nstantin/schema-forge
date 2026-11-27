//! A design's model: every row of every table of the shared model and of every plugin, as the database holds it, and
//! its SHA-256. Two models with the same hash are the same model: what undo, restore and a locked version are proven by.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use schema_forge_store::{StoreError, Transaction};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::DesignId;

/// The tables of the shared model, in the cortex.
pub const MODEL_TABLES: [&str; 8] = [
    "namespaces",
    "objects",
    "columns",
    "indexes",
    "index_parts",
    "constraints",
    "constraint_columns",
    "dependencies",
];

/// Every row of a design's model, by table (`cortex.objects`, `engine_mysql.tables`), each table's rows in id order.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Model {
    /// The rows, by table.
    pub tables: BTreeMap<String, Vec<Value>>,
}

impl Model {
    /// The SHA-256 of the model, as 64 hexadecimal digits: of its tables in name order, each row with its columns in
    /// name order.
    #[must_use]
    pub fn hash(&self) -> String {
        let bytes = serde_json::to_vec(&self.tables).unwrap_or_default();
        Sha256::digest(&bytes)
            .iter()
            .fold(String::with_capacity(64), |mut out, b| {
                let _ = write!(out, "{b:02x}");
                out
            })
    }

    /// How many rows in all.
    #[must_use]
    pub fn rows(&self) -> usize {
        self.tables.values().map(Vec::len).sum()
    }
}

/// Reads a design's whole model in a transaction: the shared model's tables and every plugin's, as registered.
pub(crate) async fn read(tx: &Transaction<'_>, design: DesignId) -> Result<Model, StoreError> {
    let mut names: Vec<String> = MODEL_TABLES.iter().map(|t| format!("cortex.{t}")).collect();
    for row in tx
        .query(
            "SELECT p.namespace || '.' || t.name FROM cortex.plugin_tables t JOIN cortex.plugins p ON p.id = t.plugin ORDER BY 1",
            &[],
        )
        .await?
    {
        names.push(row.get(0));
    }
    let mut tables = BTreeMap::new();
    for name in names {
        // names come from the catalog; they are checked before they are put in a statement
        if !is_table_name(&name) {
            return Err(StoreError::Invalid(format!("{name} is not a table name")));
        }
        let row = tx
            .query_one(
                &format!(
                    "SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.id), '[]') FROM {name} r WHERE r.design = $1"
                ),
                &[&design],
            )
            .await?;
        let rows: Value = row.get(0);
        let rows = match rows {
            Value::Array(rows) => rows,
            other => vec![other],
        };
        tables.insert(name, rows);
    }
    Ok(Model { tables })
}

fn is_table_name(name: &str) -> bool {
    let part = |s: &str| {
        s.starts_with(|c: char| c.is_ascii_lowercase())
            && s.chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
    };
    matches!(name.split_once('.'), Some((ns, t)) if part(ns) && part(t))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hash_is_the_rows_not_their_order_of_keys() {
        let a: Value = serde_json::from_str(r#"{"id": 1, "name": "a"}"#).unwrap();
        let b: Value = serde_json::from_str(r#"{"name": "a", "id": 1}"#).unwrap();
        let one = Model {
            tables: BTreeMap::from([("cortex.objects".to_string(), vec![a])]),
        };
        let two = Model {
            tables: BTreeMap::from([("cortex.objects".to_string(), vec![b])]),
        };
        assert_eq!(one.hash(), two.hash());
        assert_eq!(one.hash().len(), 64);
    }

    #[test]
    fn only_plain_names_reach_a_statement() {
        assert!(is_table_name("engine_mysql.tables"));
        assert!(!is_table_name("cortex.objects; DROP TABLE x"));
        assert!(!is_table_name("objects"));
        assert!(!is_table_name("Cortex.objects"));
    }
}
