//! The spec check (specs/tasks/SF-93-spec-check.xml): reads specs/ and every owner's folder of the repository and returns every
//! place they break the shape the task file gives, one finding each. `check` is steps 1 to 12 and 14, on files alone;
//! `load` is step 13, on PostgreSQL 18 in Docker.

mod load;
mod lock;
mod owners;
mod specs;

use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

/// One place the specs or an owner's folder break their shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub at: String,
    pub says: String,
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.at, self.says)
    }
}

/// Steps 1 to 12 and 14: the spec files, the owners' folders and the lock, read as files.
pub fn check(root: &Path) -> Vec<Finding> {
    let mut found = Vec::new();
    specs::check(root, &mut found);
    owners::check(root, &mut found);
    lock::check(root, &mut found);
    found
}

/// Step 13: every owner's folder loaded on PostgreSQL 18 in Docker, as the root's method orders its versions.
pub fn load(root: &Path) -> Vec<Finding> {
    let mut found = Vec::new();
    load::check(root, &mut found);
    found
}

/// A finding at `at` that says `says`.
fn finding(found: &mut Vec<Finding>, at: impl Into<String>, says: impl Into<String>) {
    found.push(Finding { at: at.into(), says: says.into() });
}

/// A path as the repository writes it: from its root, with forward slashes.
fn rel(root: &Path, path: &Path) -> String {
    path.strip_prefix(root).unwrap_or(path).to_string_lossy().replace('\\', "/")
}

/// The files directly in a folder whose names end with `ext`, in name order; none when the folder is missing.
fn files_in(dir: &Path, ext: &str) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| p.is_file() && p.to_string_lossy().ends_with(ext))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

/// The folders directly in a folder, in name order, hidden ones aside.
fn dirs_in(dir: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| p.is_dir() && !name(p).starts_with('.'))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

/// Every file under a folder, its subfolders included, hidden ones aside, in path order.
fn files_under(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = fs::read_dir(&d) else { continue };
        for e in entries.filter_map(Result::ok) {
            let p = e.path();
            if name(&p).starts_with('.') {
                continue;
            }
            if p.is_dir() {
                stack.push(p);
            } else if p.is_file() {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

/// A path's last part.
fn name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// A file's name without its extension.
fn stem(path: &Path) -> String {
    path.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Every run of whitespace as one space, and none at either end.
fn spaced(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The text of a file as a quote is compared with it: an XML file's parsed text, any other file's bytes as UTF-8.
fn text_of(path: &Path) -> String {
    let raw = fs::read_to_string(path).unwrap_or_default();
    if path.extension().is_some_and(|e| e == "xml")
        && let Ok(doc) = roxmltree::Document::parse(&raw)
    {
        let parts: Vec<&str> = doc.descendants().filter(|n| n.is_text()).filter_map(|n| n.text()).collect();
        return spaced(&parts.join(" "));
    }
    spaced(&raw)
}

/// An owner of the database's design: where its card is, where its folder is, and what it is.
#[derive(Debug, Clone)]
struct Owner {
    /// Its root, which holds owner.toml, from the repository's root: schema/cortex, engines/mysql.
    root: String,
    /// Its folder of tables, rules, seeds and migrations: schema/cortex, engines/mysql/schema.
    folder: String,
    /// The kind its place gives it: core, engine or feature.
    kind: &'static str,
    /// The id its place gives it: the root's name, cortex, or example for the template.
    id: String,
}

/// Every owner of the repository: the two core owners (the cortex, which holds the workspace too, and the ui), every
/// engine, every feature and the template.
fn owners(root: &Path) -> Vec<Owner> {
    let mut out = vec![
        Owner { root: "schema/cortex".into(), folder: "schema/cortex".into(), kind: "core", id: "cortex".into() },
        Owner { root: "schema/ui".into(), folder: "schema/ui".into(), kind: "core", id: "ui".into() },
    ];
    for (parent, kind) in [("engines", "engine"), ("features", "feature")] {
        for dir in dirs_in(&root.join(parent)) {
            let n = name(&dir);
            out.push(Owner { root: format!("{parent}/{n}"), folder: format!("{parent}/{n}/schema"), kind, id: n });
        }
    }
    out.push(Owner {
        root: "docs/owner-template".into(),
        folder: "docs/owner-template/schema".into(),
        kind: "engine",
        id: "example".into(),
    });
    out
}

impl Owner {
    /// The namespace its kind gives it: the id for a core owner or a feature, engine_<id> for an engine.
    fn namespace(&self) -> String {
        if self.kind == "engine" { format!("engine_{}", self.id) } else { self.id.clone() }
    }
}
