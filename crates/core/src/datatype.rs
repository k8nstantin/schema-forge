//! A column's type, the way its target spells it, held as structure (docs/model.md, Types).

use serde::{Deserialize, Serialize};

use crate::Id;

/// A type: its name in the target, and whatever the name takes. Only the fields that type uses are set.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DataType {
    /// The target's own name, lowercase: `varchar`, `numeric`, `timestamp`, `long`, `struct`; `verbatim` for a type
    /// kept exactly as read.
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub length: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub precision: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<i32>,
    /// MySQL `UNSIGNED`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub unsigned: bool,
    /// PostgreSQL `timestamp`/`time` `WITH TIME ZONE`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub with_time_zone: bool,
    /// MySQL `ENUM`/`SET` values, in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub values: Vec<String>,
    /// The element of an array (PostgreSQL) or a list (Iceberg), or a map's value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub of: Option<Box<DataType>>,
    /// A map's key (Iceberg).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<Box<DataType>>,
    /// Iceberg: the list element's, or the map value's, field id, and whether it can be null.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub element_id: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_id: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub element_nullable: Option<bool>,
    /// An Iceberg struct's fields.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fields: Vec<StructField>,
    /// PostgreSQL: a user-defined type in the schema (`types`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "type")]
    pub user_type: Option<Id>,
    /// PostgreSQL array dimensions beyond the first, kept for round trips (`int[][]`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dimensions: Option<u32>,
    /// MySQL `CHARACTER SET` on the column's type.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub charset: Option<String>,
    /// The type exactly as read, when the model does not describe it (`name` is `verbatim`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// One field of an Iceberg struct.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StructField {
    pub field_id: i32,
    pub name: String,
    pub nullable: bool,
    #[serde(rename = "type")]
    pub data_type: DataType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
}

impl DataType {
    /// A type by name alone (`text`, `bigint`, `long`).
    #[must_use]
    pub fn named(name: &str) -> Self {
        Self { name: name.to_string(), ..Self::default() }
    }

    /// A type the model does not describe, kept exactly as read.
    #[must_use]
    pub fn verbatim(text: &str) -> Self {
        Self { name: "verbatim".to_string(), text: Some(text.to_string()), ..Self::default() }
    }

    /// Gives every nested field, list element and map key and value its Iceberg field id, from `next`, the way
    /// Iceberg does: a struct's fields first, then into each in turn.
    pub fn assign_field_ids(&mut self, next: &mut i32) {
        match self.name.as_str() {
            "struct" => {
                for f in &mut self.fields {
                    f.field_id = *next;
                    *next += 1;
                }
                for f in &mut self.fields {
                    f.data_type.assign_field_ids(next);
                }
            }
            "list" => {
                self.element_id = Some(*next);
                *next += 1;
                if let Some(of) = &mut self.of {
                    of.assign_field_ids(next);
                }
            }
            "map" => {
                self.key_id = Some(*next);
                self.element_id = Some(*next + 1);
                *next += 2;
                if let Some(k) = &mut self.key {
                    k.assign_field_ids(next);
                }
                if let Some(v) = &mut self.of {
                    v.assign_field_ids(next);
                }
            }
            _ => {}
        }
    }

    /// Whether this type is kept as read rather than described.
    #[must_use]
    pub fn is_verbatim(&self) -> bool {
        self.name == "verbatim"
    }
}
