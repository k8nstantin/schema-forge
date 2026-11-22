//! The skeleton's own checks: what makes a schema broken whatever its engine. What makes it wrong for its engine is
//! the engine's to check.

use std::collections::{HashMap, HashSet};
use std::fmt;

use crate::{FORMAT, Id, Schema};

/// What is wrong, and where.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    /// The part it is about, when it is about one.
    pub at: Option<Id>,
    pub message: String,
}

impl fmt::Display for Problem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.at {
            Some(id) => write!(f, "{id}: {}", self.message),
            None => f.write_str(&self.message),
        }
    }
}

/// Everything that breaks the skeleton: none means it holds together. Names are compared exactly; whether two names
/// that differ only in case clash is the engine's rule.
#[must_use]
pub fn check(s: &Schema) -> Vec<Problem> {
    let mut out = Vec::new();
    let mut problem = |at: Option<&Id>, message: String| out.push(Problem { at: at.cloned(), message });

    if s.format != FORMAT {
        problem(None, format!("format {} is not format {FORMAT}", s.format));
    }
    if s.engine.id.trim().is_empty() {
        problem(None, "the schema names no engine".to_string());
    }
    if s.engine.version.trim().is_empty() {
        problem(None, "the schema names no version of its engine".to_string());
    }

    let mut seen = HashSet::new();
    for id in s.ids() {
        if !seen.insert(id) {
            problem(Some(id), "this id is used twice".to_string());
        }
    }

    let namespaces: HashSet<&Id> = s.namespaces.iter().map(|n| &n.id).collect();
    let mut siblings: HashMap<(Option<&Id>, &str), usize> = HashMap::new();
    for n in &s.namespaces {
        if n.name.trim().is_empty() {
            problem(Some(&n.id), "a namespace without a name".to_string());
        }
        if let Some(p) = &n.parent
            && !namespaces.contains(p)
        {
            problem(Some(&n.id), format!("its parent {p} is not a namespace of the schema"));
        }
        *siblings.entry((n.parent.as_ref(), n.name.as_str())).or_default() += 1;
        // A namespace that is its own ancestor.
        let mut at = n.parent.as_ref();
        let mut steps = 0;
        while let Some(p) = at {
            if p == &n.id || steps > s.namespaces.len() {
                problem(Some(&n.id), "it is inside itself".to_string());
                break;
            }
            at = s.namespace(p).and_then(|x| x.parent.as_ref());
            steps += 1;
        }
    }
    for n in &s.namespaces {
        if siblings.get(&(n.parent.as_ref(), n.name.as_str())).copied().unwrap_or(0) > 1 {
            problem(Some(&n.id), format!("another namespace beside it is called `{}`", n.name));
        }
    }

    let objects: HashMap<&Id, &crate::Object> = s.objects.iter().map(|o| (&o.id, o)).collect();
    let areas: HashSet<&Id> = s.areas.iter().map(|a| &a.id).collect();
    let mut in_namespace: HashMap<(&Id, &str), usize> = HashMap::new();
    for o in &s.objects {
        *in_namespace.entry((&o.namespace, o.name.as_str())).or_default() += 1;
    }
    for o in &s.objects {
        if o.name.trim().is_empty() {
            problem(Some(&o.id), "an object without a name".to_string());
        }
        if o.kind.trim().is_empty() {
            problem(Some(&o.id), "an object without a kind".to_string());
        }
        if !namespaces.contains(&o.namespace) {
            problem(Some(&o.id), format!("its namespace {} is not a namespace of the schema", o.namespace));
        } else if in_namespace.get(&(&o.namespace, o.name.as_str())).copied().unwrap_or(0) > 1 {
            problem(Some(&o.id), format!("another object in its namespace is called `{}`", o.name));
        }
        if let Some(a) = &o.area
            && !areas.contains(a)
        {
            problem(Some(&o.id), format!("its area {a} is not an area of the schema"));
        }
        for r in &o.reads {
            if !objects.contains_key(r) {
                problem(Some(&o.id), format!("it reads {r}, which is not an object of the schema"));
            } else if r == &o.id {
                problem(Some(&o.id), "it reads itself".to_string());
            }
        }
        let mut names = HashSet::new();
        for c in &o.columns {
            if c.name.trim().is_empty() {
                problem(Some(&c.id), "a column without a name".to_string());
            } else if !names.insert(c.name.as_str()) {
                problem(Some(&c.id), format!("`{}` has another column called `{}`", o.name, c.name));
            }
            if c.data_type.trim().is_empty() {
                problem(Some(&c.id), "a column without a type".to_string());
            }
        }
    }

    for l in &s.links {
        for (end, which) in [(&l.from, "from"), (&l.to, "to")] {
            let Some(o) = objects.get(&end.object) else {
                problem(Some(&l.id), format!("it links {which} {}, which is not an object of the schema", end.object));
                continue;
            };
            if end.columns.is_empty() {
                problem(Some(&l.id), format!("it links {which} no columns"));
            }
            for c in &end.columns {
                if !o.columns.iter().any(|x| &x.id == c) {
                    problem(Some(&l.id), format!("it links {which} {c}, which is not a column of `{}`", o.name));
                }
            }
        }
        if l.from.columns.len() != l.to.columns.len() {
            problem(Some(&l.id), format!("it links {} columns to {}", l.from.columns.len(), l.to.columns.len()));
        }
    }

    let mut area_names = HashSet::new();
    for a in &s.areas {
        if a.name.trim().is_empty() {
            problem(Some(&a.id), "an area without a name".to_string());
        } else if !area_names.insert(a.name.as_str()) {
            problem(Some(&a.id), format!("another area is called `{}`", a.name));
        }
    }
    out
}
