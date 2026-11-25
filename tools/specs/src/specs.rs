//! Steps 1 to 7: the spec files, the root, the open decisions, the rules, every task file, its quotes and its paths.

use crate::{Finding, dirs_in, files_in, files_under, finding, name, rel, spaced, stem, text_of};
use roxmltree::{Document, Node};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

const TASK_CHILDREN: &[&str] = &[
    "start",
    "piece",
    "before",
    "after",
    "reflects",
    "reads",
    "command",
    "build",
    "agent-decides",
    "gates",
    "owns",
    "forbid",
    "done",
];
const BRIEF_CHILDREN: &[&str] = &[
    "welcome",
    "agent-file",
    "page-note",
    "page-agent",
    "intro",
    "prompt",
    "if-task-file",
    "architecture",
    "method",
    "ways",
    "wanted",
    "first-steps",
    "start",
    "read",
    "database",
    "helping",
];

/// A task of the root's sequence.
struct Task {
    id: String,
    name: String,
    key: Option<String>,
    file: Option<String>,
}

pub fn check(root: &Path, found: &mut Vec<Finding>) {
    let mut files: Vec<String> = ["specs/root.xml", "specs/rules.xml", "specs/lessons.xml", "specs/brief.xml"]
        .iter()
        .map(|s| (*s).to_string())
        .collect();
    files.extend(files_in(&root.join("specs/tasks"), ".xml").iter().map(|p| rel(root, p)));
    files.extend(files_in(&root.join("specs/guides"), ".xml").iter().map(|p| rel(root, p)));
    files.sort();

    // step 1: every spec file is XML
    let mut texts = BTreeMap::new();
    for f in &files {
        let raw = fs::read_to_string(root.join(f)).unwrap_or_default();
        match Document::parse(&raw) {
            Ok(_) => {
                texts.insert(f.clone(), raw);
            }
            Err(e) => finding(found, f, format!("not XML: {e}")),
        }
    }
    let doc = |f: &str| texts.get(f).and_then(|raw| Document::parse(raw).ok());

    if let Some(d) = doc("specs/lessons.xml") {
        lessons(&d, found);
    }
    if let Some(d) = doc("specs/brief.xml") {
        brief(&d, found);
    }
    for f in texts.keys().filter(|f| f.starts_with("specs/guides/")) {
        if let Some(d) = doc(f) {
            guide(f, &d, found);
        }
    }

    // step 2: the root
    let sequence = doc("specs/root.xml").map(|d| root_xml(root, &d, found)).unwrap_or_default();

    // step 3: no task is written while a decision that closes before it is open
    if let Some(d) = doc("specs/root.xml") {
        open_decisions(root, &d, &sequence, &texts, found);
    }

    // step 4: the rules
    if let Some(d) = doc("specs/rules.xml") {
        rules(&d, found);
    }

    // step 5: every task file
    for f in texts.keys().filter(|f| f.starts_with("specs/tasks/")) {
        if let Some(d) = doc(f) {
            task_file(f, &d, &sequence, found);
        }
    }

    // steps 6 and 7: quotes and paths, in every spec file
    let built: Vec<String> = doc("specs/root.xml")
        .map(|d| {
            d.descendants()
                .filter(|n| n.has_tag_name("task"))
                .filter_map(|n| n.attribute("builds"))
                .flat_map(|b| b.split_whitespace().map(str::to_string).collect::<Vec<_>>())
                .collect()
        })
        .unwrap_or_default();
    for (f, raw) in &texts {
        if let Ok(d) = Document::parse(raw) {
            quotes(root, f, &d, found);
            paths(root, f, &d, &built, found);
        }
    }
}

fn elements<'a>(node: Node<'a, 'a>) -> Vec<Node<'a, 'a>> {
    node.children().filter(Node::is_element).collect()
}

fn text(node: Node) -> String {
    spaced(&node.descendants().filter(|n| n.is_text()).filter_map(|n| n.text()).collect::<Vec<_>>().join(" "))
}

fn lessons(d: &Document, found: &mut Vec<Finding>) {
    for lesson in d.root_element().children().filter(|n| n.has_tag_name("lesson")) {
        let id = lesson.attribute("id").unwrap_or("?");
        for part in ["found", "seen", "does"] {
            let n: Vec<_> = lesson.children().filter(|c| c.has_tag_name(part)).collect();
            if n.len() != 1 || text(n[0]).is_empty() {
                finding(found, "specs/lessons.xml", format!("lesson {id} has no {part}"));
            }
        }
    }
}

fn brief(d: &Document, found: &mut Vec<Finding>) {
    let names: Vec<_> = elements(d.root_element()).iter().map(|n| n.tag_name().name().to_string()).collect();
    for (i, want) in BRIEF_CHILDREN.iter().enumerate() {
        if names.get(i).map(String::as_str) != Some(*want) {
            finding(found, "specs/brief.xml", format!("{want} missing or out of order"));
            break;
        }
    }
    for g in d.descendants().filter(|n| n.has_tag_name("group")) {
        let ok = g.attribute("path").is_some()
            || g.attribute("paths").is_some()
            || matches!(g.attribute("source"), Some("authority" | "sequence" | "guides" | "docs"));
        if !ok {
            finding(found, "specs/brief.xml", format!("group {} has no files", g.attribute("name").unwrap_or("?")));
        }
    }
}

fn guide(f: &str, d: &Document, found: &mut Vec<Finding>) {
    let g = d.root_element();
    if g.tag_name().name() != "guide" || g.attribute("id") != Some(stem(Path::new(f)).as_str()) {
        finding(found, f, "the guide is not named as its file");
    }
    for attr in ["for", "version", "date"] {
        if g.attribute(attr).is_none() {
            finding(found, f, format!("the guide has no {attr}"));
        }
    }
    let kids = elements(g);
    let names: Vec<&str> = kids.iter().map(|n| n.tag_name().name()).collect();
    let phases: Vec<&Node> = kids.iter().filter(|n| n.has_tag_name("phase")).collect();
    let mut want = vec!["start", "goal", "boundaries"];
    want.extend(std::iter::repeat_n("phase", phases.len()));
    want.extend(["whole", "stop", "reference"]);
    if names != want {
        finding(found, f, "start, goal, boundaries, phases, whole, stop and reference missing or out of order");
    }
    let numbered = phases.iter().enumerate().all(|(i, p)| p.attribute("n") == Some((i + 1).to_string().as_str()));
    if phases.is_empty() || !numbered {
        finding(found, f, "phases not numbered in order");
    }
}

fn root_xml(root: &Path, d: &Document, found: &mut Vec<Finding>) -> Vec<Task> {
    const AT: &str = "specs/root.xml";
    let r = d.root_element();
    for attr in ["product", "version", "date"] {
        if r.attribute(attr).is_none() {
            finding(found, AT, format!("no {attr}"));
        }
    }
    let names: Vec<_> = elements(r).iter().map(|n| n.tag_name().name().to_string()).collect();
    let want = ["identity", "authority", "method", "sequence", "decisions"];
    for w in want {
        if !names.iter().any(|n| n == w) {
            finding(found, AT, format!("no {w}"));
        }
    }
    let mut tasks = Vec::new();
    let (mut ids, mut keys) = (BTreeSet::new(), BTreeSet::new());
    for t in
        d.descendants().filter(|n| n.has_tag_name("task") && n.parent().is_some_and(|p| p.has_tag_name("sequence")))
    {
        let id = t.attribute("id").unwrap_or("").to_string();
        let tname = t.attribute("name").unwrap_or("").to_string();
        let valid_id = id.len() == 3 && id.starts_with('t') && id[1..].chars().all(|c| c.is_ascii_digit());
        if !valid_id || tname.is_empty() || !ids.insert(id.clone()) {
            finding(found, AT, format!("task {id} has no unique id or no name"));
        }
        match t.attribute("title") {
            Some(title) if title.chars().count() <= 80 && !title.is_empty() => {}
            _ => finding(found, AT, format!("task {id} has no title of at most 80 characters")),
        }
        let key = t.attribute("key").map(str::to_string);
        if let Some(k) = &key {
            let valid = k.strip_prefix("SF-").is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()));
            if !valid || !keys.insert(k.clone()) {
                finding(found, AT, format!("task {id} has key {k}, which is not SF-<digits> or not unique"));
            }
        }
        if let Some(dep) = t.attribute("depends")
            && !tasks.iter().any(|x: &Task| x.id == dep)
        {
            finding(found, AT, format!("task {id} depends on {dep}, which is no earlier task"));
        }
        let file = t.attribute("file").map(str::to_string);
        match &file {
            Some(f) => {
                let want = match &key {
                    Some(k) => format!("specs/tasks/{k}-{}.xml", tname.replace(' ', "-")),
                    None => format!("specs/tasks/{id}-{}.xml", tname.replace(' ', "-")),
                };
                if !root.join(f).is_file() {
                    finding(found, AT, format!("task {id} names {f}, which does not exist"));
                } else if *f != want {
                    finding(found, AT, format!("task {id} names {f}, which is not its file name"));
                }
            }
            None => {
                if !text(t).starts_with("Not written yet") {
                    finding(found, AT, format!("task {id} has no file and does not say it is not written yet"));
                }
            }
        }
        tasks.push(Task { id, name: tname, key, file });
    }
    for dec in d.descendants().filter(|n| n.has_tag_name("decision")) {
        let id = dec.attribute("id").unwrap_or("?");
        let status = dec.attribute("status");
        if !matches!(status, Some("confirmed" | "open"))
            || (dec.attribute("where").is_none() && dec.attribute("closes-before").is_none())
        {
            finding(found, AT, format!("decision {id} has no status or no where"));
        }
        if status == Some("confirmed") && dec.attribute("date").is_none() {
            finding(found, AT, format!("decision {id} has no date"));
        }
        if status == Some("open") {
            let cb = dec.attribute("closes-before").unwrap_or("");
            if !tasks.iter().any(|t| t.id == cb) {
                finding(found, AT, format!("decision {id} closes before {cb}, which is no task"));
            }
        }
    }
    tasks
}

fn open_decisions(
    root: &Path,
    d: &Document,
    tasks: &[Task],
    texts: &BTreeMap<String, String>,
    found: &mut Vec<Finding>,
) {
    for dec in d.descendants().filter(|n| n.has_tag_name("decision") && n.attribute("status") == Some("open")) {
        let id = dec.attribute("id").unwrap_or("?");
        let Some(from) = tasks.iter().position(|t| Some(t.id.as_str()) == dec.attribute("closes-before")) else {
            continue;
        };
        for t in &tasks[from..] {
            if t.file.is_some() {
                finding(found, "specs/root.xml", format!("task {} is written while decision {id} is open", t.id));
            }
            for (f, raw) in texts.iter().filter(|(f, _)| f.starts_with("specs/tasks/")) {
                let written = Document::parse(raw).is_ok_and(|x| x.root_element().attribute("id") == Some(&t.id));
                if written {
                    finding(found, f, format!("task {} is written while decision {id} is open", t.id));
                }
            }
        }
    }
    let _ = root;
}

fn rules(d: &Document, found: &mut Vec<Finding>) {
    let mut ids = BTreeSet::new();
    for rule in d.root_element().children().filter(|n| n.has_tag_name("rule")) {
        let id = rule.attribute("id").unwrap_or("?");
        if !ids.insert(id.to_string()) {
            finding(found, "specs/rules.xml", format!("rule {id} is not unique"));
        }
        for part in ["from", "text", "breach"] {
            let n: Vec<_> = rule.children().filter(|c| c.has_tag_name(part)).collect();
            if n.len() != 1 || text(n[0]).is_empty() {
                finding(found, "specs/rules.xml", format!("rule {id} has no {part}"));
            }
        }
    }
}

/// The name of the test an item of a tests element gives, by the root's method tests.
pub fn test_name(item: &str) -> String {
    let mut out = String::new();
    for c in item.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            out.push(c);
        } else if !out.ends_with('_') {
            out.push('_');
        }
    }
    out.trim_matches('_').to_string()
}

fn task_file(f: &str, d: &Document, tasks: &[Task], found: &mut Vec<Finding>) {
    let t = d.root_element();
    let names: Vec<_> = elements(t).iter().map(|n| n.tag_name().name().to_string()).collect();
    for (i, want) in TASK_CHILDREN.iter().enumerate() {
        if names.get(i).map(String::as_str) != Some(*want) {
            finding(found, f, format!("{want} missing or out of order"));
            break;
        }
    }
    let (id, tname, key) = (t.attribute("id"), t.attribute("name"), t.attribute("key"));
    let ours = tasks.iter().any(|x| {
        Some(x.id.as_str()) == id
            && Some(x.name.as_str()) == tname
            && x.key.as_deref() == key
            && x.file.as_deref() == Some(f)
    });
    if !ours {
        finding(found, f, format!("task {} {} is not the root's", id.unwrap_or("?"), tname.unwrap_or("?")));
    }
    let version = t.attribute("version").unwrap_or("?");
    let start = t.children().find(|n| n.has_tag_name("start")).map(text).unwrap_or_default();
    if !start.contains(&format!("-v{version}-")) || !start.contains(&format!(" v{version} · ")) {
        finding(found, f, format!("start does not carry version {version}"));
    }
    let steps: Vec<String> = t
        .descendants()
        .filter(|n| n.has_tag_name("step"))
        .map(|n| n.attribute("n").unwrap_or("").to_string())
        .collect();
    if steps.iter().enumerate().any(|(i, n)| *n != (i + 1).to_string()) {
        finding(found, f, "steps not numbered in order");
    }
    let mut names = BTreeSet::new();
    for p in t.descendants().filter(|n| n.has_tag_name("prove")) {
        let s = p.attribute("step").unwrap_or("");
        if !steps.iter().any(|n| n == s) {
            finding(found, f, format!("prove names step {s}, which is none"));
        }
        let n = test_name(&text(p));
        if !names.insert(n.clone()) {
            finding(found, f, format!("two items give the test name {n}"));
        }
    }
    for g in t.descendants().filter(|n| n.has_tag_name("gate")) {
        let id = g.attribute("id").unwrap_or("?");
        let lacks = if !matches!(g.attribute("kind"), Some("local" | "docker" | "ci")) {
            Some("a kind")
        } else if g.attribute("proves").is_none() {
            Some("proves")
        } else if !g.children().any(|c| c.has_tag_name("cmd")) {
            Some("a cmd")
        } else if !g.children().any(|c| c.has_tag_name("expect")) {
            Some("an expect")
        } else {
            None
        };
        if let Some(what) = lacks {
            finding(found, f, format!("gate {id} lacks {what}"));
        }
    }
}

/// A path attribute's value with <engine> standing for every folder under engines/.
fn expand(root: &Path, value: &str) -> Vec<String> {
    if value.contains("<engine>") {
        dirs_in(&root.join("engines")).iter().map(|d| value.replace("<engine>", &name(d))).collect()
    } else {
        vec![value.to_string()]
    }
}

fn quotes(root: &Path, f: &str, d: &Document, found: &mut Vec<Finding>) {
    for q in d.descendants().filter(|n| n.has_tag_name("quote")) {
        let Some(holder) = q.ancestors().find(|a| a.attribute("path").is_some()) else { continue };
        let value = holder.attribute("path").unwrap_or("");
        let quote = text(q);
        let held = expand(root, value).iter().any(|v| {
            let p = root.join(v);
            if p.is_dir() {
                files_under(&p).iter().any(|file| text_of(file).contains(&quote))
            } else {
                text_of(&p).contains(&quote)
            }
        });
        if !held {
            let first: String = quote.chars().take(60).collect();
            finding(found, f, format!("quote not in {value}: {first}"));
        }
    }
}

fn paths(root: &Path, f: &str, d: &Document, built: &[String], found: &mut Vec<Finding>) {
    let built_by = |v: &str| built.iter().any(|b| v == b || v.starts_with(&format!("{}/", b.trim_end_matches('/'))));
    for n in d.descendants().filter(Node::is_element) {
        let mut values: Vec<String> = n.attribute("path").map(|p| vec![p.to_string()]).unwrap_or_default();
        if let Some(b) = n.attribute("builds") {
            values.extend(b.split_whitespace().map(str::to_string));
        }
        for value in values {
            for v in expand(root, &value) {
                if !root.join(&v).exists() && !built_by(&v) {
                    finding(found, f, format!("names {value}, which does not exist"));
                }
            }
        }
    }
}
