//! Rules written as sentences, which the agent proposes and the system runs: data, never code. A sentence says which
//! columns or tables it covers and what they must be; the title you read is made from the sentence itself, so a rule
//! is always exactly what it says.

use serde::{Deserialize, Serialize};

use super::checks::Outcome;
use crate::{DataType, Table, Target};

/// Which names a sentence covers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Pattern {
    EndsWith(String),
    StartsWith(String),
    Contains(String),
    Is(String),
}

impl Pattern {
    fn text(&self) -> &str {
        match self {
            Self::EndsWith(t) | Self::StartsWith(t) | Self::Contains(t) | Self::Is(t) => t,
        }
    }

    /// Whether `name` is covered; names are compared in lower case.
    #[must_use]
    pub fn covers(&self, name: &str) -> bool {
        let n = name.to_lowercase();
        let t = self.text().to_lowercase();
        match self {
            Self::EndsWith(_) => n.ends_with(&t),
            Self::StartsWith(_) => n.starts_with(&t),
            Self::Contains(_) => n.contains(&t),
            Self::Is(_) => n == t,
        }
    }

    fn words(&self) -> String {
        match self {
            Self::EndsWith(t) => format!("ending `{t}`"),
            Self::StartsWith(t) => format!("starting `{t}`"),
            Self::Contains(t) => format!("containing `{t}`"),
            Self::Is(t) => format!("named `{t}`"),
        }
    }
}

/// What every covered column must be.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum ColumnMust {
    /// One of these types, by the target's names (`timestamptz`, `string`, `long`).
    OfType(Vec<String>),
    Required,
    Described,
    SnakeCase,
}

/// A rule as a sentence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Sentence {
    /// Every column whose name matches must …
    Columns { name: Pattern, must: ColumnMust },
    /// Every table has this column; required, and of one of these types, when said.
    HasColumn {
        column: String,
        #[serde(default)]
        required: bool,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        types: Vec<String>,
    },
    /// Every table is partitioned by `transform(column)` (Iceberg).
    PartitionedBy { transform: String, column: String },
}

const TRANSFORMS: &[&str] = &["identity", "year", "month", "day", "hour", "void"];

impl Sentence {
    /// The sentence in words: the title you read.
    #[must_use]
    pub fn words(&self) -> String {
        match self {
            Self::Columns { name, must } => {
                let what = match must {
                    ColumnMust::OfType(t) => format!("are {}", t.join(" or ")),
                    ColumnMust::Required => "are required".to_string(),
                    ColumnMust::Described => "have a description".to_string(),
                    ColumnMust::SnakeCase => "are snake_case".to_string(),
                };
                format!("Columns {} {what}", name.words())
            }
            Self::HasColumn { column, required, types } => {
                let mut s = format!("Every table has `{column}`");
                if !types.is_empty() {
                    s.push_str(&format!(", {}", types.join(" or ")));
                }
                if *required {
                    s.push_str(", required");
                }
                s
            }
            Self::PartitionedBy { transform, column } => format!("Every table is partitioned by {transform}({column})"),
        }
    }

    /// What it is about, for the catalog.
    #[must_use]
    pub const fn topic(&self) -> &'static str {
        match self {
            Self::Columns { must: ColumnMust::OfType(_), .. } => "types",
            Self::Columns { must: ColumnMust::Described, .. } => "documentation",
            Self::Columns { must: ColumnMust::SnakeCase, .. } => "naming",
            Self::Columns { must: ColumnMust::Required, .. } | Self::HasColumn { .. } => "keys",
            Self::PartitionedBy { .. } => "storage",
        }
    }

    /// Whether it says something that can be checked on a `target` schema.
    ///
    /// # Errors
    /// What does not hold, in a sentence.
    pub fn valid(&self, target: Target) -> Result<(), String> {
        let types = |t: &[String]| match t.iter().find(|n| !crate::types::known(target, n) || n.as_str() == "verbatim")
        {
            Some(n) => Err(format!(
                "`{n}` is not {} type",
                match target {
                    Target::Mysql => "a MySQL",
                    Target::Postgres => "a PostgreSQL",
                    Target::Iceberg => "an Iceberg",
                }
            )),
            None => Ok(()),
        };
        match self {
            Self::Columns { name, must } => {
                if name.text().trim().is_empty() {
                    return Err("the name pattern is empty".to_string());
                }
                if let ColumnMust::OfType(t) = must {
                    if t.is_empty() {
                        return Err("say at least one type".to_string());
                    }
                    types(t)?;
                }
                Ok(())
            }
            Self::HasColumn { column, types: t, .. } => {
                if column.trim().is_empty() {
                    return Err("the column name is empty".to_string());
                }
                types(t)
            }
            Self::PartitionedBy { transform, column } => {
                if target != Target::Iceberg {
                    return Err("partition transforms are Iceberg's".to_string());
                }
                let base = transform.split('[').next().unwrap_or("");
                if !(TRANSFORMS.contains(&transform.as_str())
                    || matches!(base, "bucket" | "truncate") && transform.ends_with(']'))
                {
                    return Err(format!("`{transform}` is not a partition transform"));
                }
                if column.trim().is_empty() {
                    return Err("the column name is empty".to_string());
                }
                Ok(())
            }
        }
    }

    /// Whether column `name` of type `t` keeps the sentence; `None` when the sentence does not cover it.
    #[must_use]
    pub fn keeps_column(&self, name: &str, t: &DataType) -> Option<bool> {
        match self {
            Self::Columns { name: p, must: ColumnMust::OfType(types) } if p.covers(name) => {
                Some(types.contains(&type_name(t)))
            }
            _ => None,
        }
    }

    /// Runs the sentence on one table.
    pub(super) fn run(&self, table: &Table) -> Outcome {
        let mut o = Outcome::default();
        match self {
            Self::Columns { name, must } => {
                for c in table.columns.iter().filter(|c| name.covers(&c.name)) {
                    o.checked += 1;
                    let broken = match must {
                        ColumnMust::OfType(types) => (!types.contains(&type_name(&c.data_type)))
                            .then(|| format!("`{}` is {}", c.name, type_name(&c.data_type))),
                        ColumnMust::Required => c.nullable.then(|| format!("`{}` may be empty", c.name)),
                        ColumnMust::Described => c
                            .comment
                            .as_deref()
                            .is_none_or(|t| t.trim().is_empty())
                            .then(|| format!("`{}` has no description", c.name)),
                        ColumnMust::SnakeCase => (!snake(&c.name)).then(|| format!("`{}` is not snake_case", c.name)),
                    };
                    if let Some(m) = broken {
                        o.breaks.push((Some(c.id.clone()), m));
                    }
                }
            }
            Self::HasColumn { column, required, types } => {
                o.checked += 1;
                match table.columns.iter().find(|c| c.name.eq_ignore_ascii_case(column)) {
                    None => o.breaks.push((None, format!("`{}` has no `{column}`", table.name))),
                    Some(c) => {
                        if *required && c.nullable {
                            o.breaks.push((Some(c.id.clone()), format!("`{column}` may be empty")));
                        }
                        if !types.is_empty() && !types.contains(&type_name(&c.data_type)) {
                            o.breaks.push((Some(c.id.clone()), format!("`{column}` is {}", type_name(&c.data_type))));
                        }
                    }
                }
            }
            Self::PartitionedBy { transform, column } => {
                o.checked += 1;
                let spec = table.options.iceberg.as_ref().map(|i| i.partition_spec.as_slice()).unwrap_or_default();
                let hit = spec.iter().any(|p| {
                    p.transform == *transform
                        && table.columns.iter().any(|c| c.id == p.source && c.name.eq_ignore_ascii_case(column))
                });
                if !hit {
                    let how = if spec.is_empty() {
                        "is not partitioned".to_string()
                    } else {
                        "is partitioned otherwise".to_string()
                    };
                    o.breaks.push((None, format!("`{}` {how}", table.name)));
                }
            }
        }
        o
    }
}

/// A type by the name the sentence compares: its name, `timestamptz` for PostgreSQL's zoned timestamp.
fn type_name(t: &DataType) -> String {
    if t.name == "timestamp" && t.with_time_zone { "timestamptz".to_string() } else { t.name.clone() }
}

fn snake(n: &str) -> bool {
    n.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && n.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// Who wrote a rule and who let it in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Provenance {
    pub proposed_by: String,
    pub approved_by: String,
    /// The proposal it came from: `<schema>#<n>`.
    pub proposal: String,
}

/// A rule of the workspace, written as a sentence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CustomRule {
    /// `custom.<n>`.
    pub id: String,
    pub sentence: Sentence,
    /// Hard (enforced) unless said otherwise where it is linked.
    pub hard: bool,
    /// The targets it checks; none for every one.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub targets: Vec<Target>,
    /// The agent's evidence for it.
    pub why: String,
    pub provenance: Provenance,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sentence_reads_as_it_runs() {
        let s = Sentence::Columns {
            name: Pattern::EndsWith("_at".into()),
            must: ColumnMust::OfType(vec!["timestamptz".into()]),
        };
        assert_eq!(s.words(), "Columns ending `_at` are timestamptz");
        assert!(s.valid(Target::Iceberg).is_ok());
        assert!(
            Sentence::Columns {
                name: Pattern::EndsWith("_at".into()),
                must: ColumnMust::OfType(vec!["varchar".into()])
            }
            .valid(Target::Iceberg)
            .is_err()
        );
        let h = Sentence::HasColumn { column: "loaded_at".into(), required: true, types: vec![] };
        assert_eq!(h.words(), "Every table has `loaded_at`, required");
        assert!(
            Sentence::PartitionedBy { transform: "bucket[16]".into(), column: "id".into() }
                .valid(Target::Iceberg)
                .is_ok()
        );
        assert!(
            Sentence::PartitionedBy { transform: "weekly".into(), column: "id".into() }.valid(Target::Iceberg).is_err()
        );
        assert!(
            Sentence::PartitionedBy { transform: "day".into(), column: "at".into() }.valid(Target::Postgres).is_err()
        );
    }
}
