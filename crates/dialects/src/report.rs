//! What an import did with every statement: modelled, kept as written, or left out as data.

use std::collections::BTreeMap;
use std::fmt;

use schema_forge_core::Schema;

/// A dump read into the model, with its report.
#[derive(Debug)]
pub struct Imported {
    pub schema: Schema,
    pub report: Report,
}

/// Every statement of the dump, accounted for. `statements == modelled + kept + data`.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Report {
    pub statements: usize,
    /// Became the model (tables, keys, views, …).
    pub modelled: usize,
    /// Carried through verbatim, by kind (`function`, `grant`, …).
    pub kept: BTreeMap<String, usize>,
    /// Data left out: `COPY` blocks, `INSERT`s, sequence values.
    pub data: usize,
    pub copy_rows: usize,
    /// Partitions held as a series (their statements are kept, counted under `partitions`).
    pub partition_series: usize,
    /// Statements kept because the model could not describe them, with their line and first words.
    pub not_understood: Vec<(usize, String)>,
}

impl Report {
    #[must_use]
    pub fn kept_total(&self) -> usize {
        self.kept.values().sum()
    }

    /// Whether the counts add up to the whole dump.
    #[must_use]
    pub fn adds_up(&self) -> bool {
        self.statements == self.modelled + self.kept_total() + self.data
    }
}

impl fmt::Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "{} statements", self.statements)?;
        writeln!(f, "  modelled: {}", self.modelled)?;
        writeln!(f, "  kept as written: {}", self.kept_total())?;
        for (kind, n) in &self.kept {
            writeln!(f, "    {kind}: {n}")?;
        }
        writeln!(f, "  data, left out: {} ({} copied rows)", self.data, self.copy_rows)?;
        if self.partition_series > 0 {
            writeln!(f, "  partition series: {}", self.partition_series)?;
        }
        if !self.not_understood.is_empty() {
            writeln!(f, "  kept because not understood:")?;
            for (line, start) in &self.not_understood {
                writeln!(f, "    line {line}: {start}")?;
            }
        }
        Ok(())
    }
}
