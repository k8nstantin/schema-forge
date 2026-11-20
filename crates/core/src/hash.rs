//! A schema's content hash: its identity as a locked version (docs/model.md, Versions).

use serde_json::Value;

use crate::Schema;

/// The schema written canonically: object keys sorted at every level, no spaces. The same schema gives the
/// same text on any machine.
#[must_use]
pub fn canonical(schema: &Schema) -> String {
    let value = serde_json::to_value(schema).unwrap_or(Value::Null);
    sorted(&value).to_string()
}

/// The BLAKE3 hash of the canonical text, in hex.
#[must_use]
pub fn hash(schema: &Schema) -> String {
    blake3::hash(canonical(schema).as_bytes()).to_hex().to_string()
}

fn sorted(v: &Value) -> Value {
    match v {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let mut out = serde_json::Map::new();
            for k in keys {
                out.insert(k.clone(), sorted(&map[k]));
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(sorted).collect()),
        other => other.clone(),
    }
}
