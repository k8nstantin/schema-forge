//! Reading an engine's files into a schema, with a report that accounts for everything read.

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use schema_forge_model::Schema;

/// How much of a file is read to tell what it is: enough for any header, never a whole dump.
const HEAD: u64 = 64 * 1024;

/// What is offered to read: a file or a folder, and the start of a file. Made by [`Input::open`].
#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct Input {
    pub path: PathBuf,
    pub is_dir: bool,
    /// The first 64 KiB of a file, as text (invalid UTF-8 replaced); empty for a folder.
    pub head: String,
}

impl Input {
    /// Looks at `path`.
    ///
    /// # Errors
    /// When it cannot be read.
    pub fn open(path: &Path) -> Result<Self, String> {
        let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
        if meta.is_dir() {
            return Ok(Self { path: path.to_path_buf(), is_dir: true, head: String::new() });
        }
        let mut head = Vec::new();
        let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
        std::io::Read::read_to_end(&mut std::io::Read::take(file, HEAD), &mut head)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(Self { path: path.to_path_buf(), is_dir: false, head: String::from_utf8_lossy(&head).into_owned() })
    }
}

/// A schema read in, and what reading did with everything it read.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct Imported {
    pub schema: Schema,
    pub report: Report,
}

impl Imported {
    #[must_use]
    pub const fn new(schema: Schema, report: Report) -> Self {
        Self { schema, report }
    }
}

/// Everything read, accounted for: `read == modelled + kept + data`. A unit is what the engine reads one at a time
/// (`statements`, `files`); what is not a unit (the space between statements) is not content and is not counted.
/// Made with [`Report::new`], then counted into:
///
/// ```compile_fail
/// let r = schema_forge_engine::Report { unit: "statements", ..Default::default() };
/// ```
#[derive(Debug, Clone, Default, PartialEq, Eq)]
#[non_exhaustive]
pub struct Report {
    pub unit: &'static str,
    pub read: usize,
    /// Became the model.
    pub modelled: usize,
    /// Kept exactly as written, by kind, because the model does not describe them; written back in their place.
    pub kept: BTreeMap<String, usize>,
    /// Data, not schema, left out (rows, sequence values).
    pub data: usize,
    /// What was kept because it was not understood.
    pub not_understood: Vec<Unread>,
}

/// Something read but not understood, kept as written.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct Unread {
    /// Where it was (`line 12`, `orders/metadata/v3.metadata.json`).
    pub at: String,
    /// How it starts, enough to find it.
    pub start: String,
}

impl Unread {
    #[must_use]
    pub fn new(at: impl Into<String>, start: impl Into<String>) -> Self {
        Self { at: at.into(), start: start.into() }
    }
}

impl Report {
    /// An empty report of what is read one `unit` at a time (`statements`, `non-blank lines`, `files`).
    #[must_use]
    pub fn new(unit: &'static str) -> Self {
        Self { unit, ..Self::default() }
    }

    #[must_use]
    pub fn kept_total(&self) -> usize {
        self.kept.values().sum()
    }

    /// Whether every unit read is accounted for, once.
    #[must_use]
    pub fn adds_up(&self) -> bool {
        self.read == self.modelled + self.kept_total() + self.data
    }
}

impl fmt::Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "{} {} read", self.read, self.unit)?;
        writeln!(f, "  modelled: {}", self.modelled)?;
        writeln!(f, "  kept as written: {}", self.kept_total())?;
        for (kind, n) in &self.kept {
            writeln!(f, "    {kind}: {n}")?;
        }
        writeln!(f, "  data, left out: {}", self.data)?;
        if !self.not_understood.is_empty() {
            writeln!(f, "  kept because not understood:")?;
            for u in &self.not_understood {
                writeln!(f, "    {}: {}", u.at, u.start)?;
            }
        }
        Ok(())
    }
}

/// Reading an engine's files.
pub trait Read: Send + Sync {
    /// What it reads, in a phrase for people (`"schema-only dumps"`).
    fn reads(&self) -> &'static str;

    /// Whether `input` is something this engine reads. Only what the input itself says counts (a header, a folder's
    /// layout), never its name alone.
    fn recognises(&self, input: &Input) -> bool;

    /// Reads `input` into a schema at the engine's version the input says, or its default.
    ///
    /// # Errors
    /// When it cannot be read at all; what is read but not understood is kept and reported, never an error.
    fn read(&self, input: &Input) -> Result<Imported, String>;
}
