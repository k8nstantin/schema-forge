//! Steps 8 to 12: every owner's card, table files, rules, seeds and migrations.

use crate::{Finding, Owner, files_in, finding, name, owners, spaced, stem};
use std::fs;
use std::path::Path;

/// The eight types a column may have.
pub const TYPES: &[&str] = &["TEXT", "INTEGER", "BIGINT", "NUMERIC", "BOOLEAN", "UUID", "TIMESTAMPTZ", "JSONB"];
/// Words that start a table constraint, not a column.
const CONSTRAINTS: &[&str] = &["UNIQUE", "CHECK", "PRIMARY", "FOREIGN", "CONSTRAINT", "EXCLUDE"];
/// The cortex's tables that are no one design's (with every workspace_ table): every other table of every owner holds
/// a design's rows, carries its design, and refers to another design's table by (design, column) (decision
/// work-from-memory).
const NOT_A_DESIGN: &[&str] = &[
    "cortex.designs",
    "cortex.engine_versions",
    "cortex.engine_features",
    "cortex.catalog_sources",
    "cortex.object_kinds",
    "cortex.option_declarations",
    "cortex.schema_migrations",
];

/// The cortex's tables an engine's seeds declare it in: its versions, features, kinds, options and catalog sources.
const DECLARATIONS: &[&str] = &[
    "cortex.engine_versions",
    "cortex.engine_features",
    "cortex.object_kinds",
    "cortex.option_declarations",
    "cortex.catalog_sources",
];

/// Whether a table holds a design's rows.
pub fn of_a_design(table: &str) -> bool {
    !NOT_A_DESIGN.contains(&table) && !table.starts_with("cortex.workspace_")
}

pub fn check(root: &Path, found: &mut Vec<Finding>) {
    let all = owners(root);
    let cortex_version = card(root, &all[0]).and_then(|c| c.get("version").and_then(toml::Value::as_integer));
    for owner in &all {
        owner_card(root, owner, cortex_version, found);
        for file in files_in(&root.join(&owner.folder), ".sql") {
            sql_file(root, owner, &file, found);
        }
        for file in files_in(&root.join(&owner.folder).join("rules"), ".sql") {
            rule_file(owner, &file, &format!("{}/rules/{}", owner.folder, name(&file)), found);
        }
        for file in files_in(&root.join(&owner.folder).join("seeds"), ".sql") {
            seed_file(root, owner, &file, &format!("{}/seeds/{}", owner.folder, name(&file)), found);
        }
        migrations(root, owner, found);
    }
}

fn card(root: &Path, owner: &Owner) -> Option<toml::Table> {
    fs::read_to_string(root.join(&owner.root).join("owner.toml")).ok()?.parse::<toml::Table>().ok()
}

/// The numbers of an owner's migrations after the first: <n> of every migrations/<n>_<name>.sql but 1_tables.sql.
fn migration_numbers(root: &Path, owner: &Owner) -> (Vec<u64>, bool, Vec<String>) {
    let mut numbers = Vec::new();
    let mut first = false;
    let mut bad = Vec::new();
    for f in files_in(&root.join(&owner.folder).join("migrations"), ".sql") {
        let n = name(&f);
        if n == "1_tables.sql" {
            first = true;
            continue;
        }
        match n.split_once('_').and_then(|(num, rest)| num.parse::<u64>().ok().filter(|_| !rest.is_empty())) {
            Some(num) => numbers.push(num),
            None => bad.push(n),
        }
    }
    numbers.sort_unstable();
    (numbers, first, bad)
}

fn owner_card(root: &Path, owner: &Owner, cortex_version: Option<i64>, found: &mut Vec<Finding>) {
    let at = format!("{}/owner.toml", owner.root);
    let Some(c) = card(root, owner) else {
        finding(found, &at, "no id");
        return;
    };
    let mut keys = vec!["id", "kind", "namespace", "version"];
    if owner.kind != "core" {
        keys.push("requires_cortex");
    }
    for k in &keys {
        if !c.contains_key(*k) {
            finding(found, &at, format!("no {k}"));
        }
    }
    let wrong = |found: &mut Vec<Finding>, key: &str, value: &dyn std::fmt::Display, want: &str| {
        finding(found, &at, format!("{key} is {value}, not {want}"));
    };
    if let Some(id) = c.get("id").and_then(toml::Value::as_str) {
        let chars = !id.is_empty() && id.chars().all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_');
        if !chars || id != owner.id {
            wrong(found, "id", &id, &owner.id);
        }
    }
    if let Some(kind) = c.get("kind").and_then(toml::Value::as_str)
        && kind != owner.kind
    {
        wrong(found, "kind", &kind, owner.kind);
    }
    if let Some(ns) = c.get("namespace").and_then(toml::Value::as_str)
        && ns != owner.namespace()
    {
        wrong(found, "namespace", &ns, &owner.namespace());
    }
    let (numbers, _, _) = migration_numbers(root, owner);
    let want = numbers.last().copied().unwrap_or(1);
    if let Some(v) = c.get("version").and_then(toml::Value::as_integer)
        && u64::try_from(v).ok() != Some(want)
    {
        wrong(found, "version", &v, &want.to_string());
    }
    if owner.kind != "core"
        && let Some(r) = c.get("requires_cortex").and_then(toml::Value::as_integer)
        && (r < 1 || cortex_version.is_some_and(|cv| r > cv))
    {
        wrong(found, "requires_cortex", &r, "at least 1 and at most the cortex's version");
    }
}

/// A SQL string literal's text: the quotes off, every doubled quote one.
fn literal(s: &str) -> Option<String> {
    let s = s.trim().trim_end_matches(';').trim();
    let inner = s.strip_prefix('\'')?.strip_suffix('\'')?;
    Some(inner.replace("''", "'"))
}

/// A line split at its `--` comment, outside quotes: the code and the comment's words.
pub fn split_comment(line: &str) -> (String, Option<String>) {
    let mut quoted = false;
    let bytes = line.as_bytes();
    for i in 0..bytes.len() {
        if bytes[i] == b'\'' {
            quoted = !quoted;
        } else if !quoted && bytes[i] == b'-' && bytes.get(i + 1) == Some(&b'-') {
            return (line[..i].trim_end().to_string(), Some(line[i + 2..].trim().to_string()));
        }
    }
    (line.trim_end().to_string(), None)
}

/// A column definition's name and type, when the line starts one.
pub fn column(code: &str) -> Option<(String, String)> {
    if !code.starts_with(' ') {
        return None;
    }
    let mut words = code.split_whitespace();
    let col = words.next()?;
    let ty = words.next()?.trim_end_matches(',');
    let bare = col.trim_matches('"');
    let named = !bare.is_empty() && bare.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    let upper = ty.chars().all(|c| c.is_ascii_uppercase());
    if named && upper && !CONSTRAINTS.contains(&col) && !ty.is_empty() {
        Some((bare.to_string(), ty.to_string()))
    } else {
        None
    }
}

fn sql_file(root: &Path, owner: &Owner, file: &Path, found: &mut Vec<Finding>) {
    let at = format!("{}/{}", owner.folder, name(file));
    let text = fs::read_to_string(file).unwrap_or_default();
    let lines: Vec<&str> = text.lines().collect();
    let Some(create) = lines.iter().position(|l| l.starts_with("CREATE TABLE ")) else {
        let allowed = owner.id == "cortex"
            && matches!(
                name(file).as_str(),
                "enforce_rules.sql" | "check_options.sql" | "check_kinds.sql" | "notify_turns.sql" | "grant_roles.sql"
            );
        if !allowed {
            finding(found, &at, "neither a table file nor a file the method names");
        }
        return;
    };
    let ns = owner.namespace();
    let table = format!("{ns}.{}", stem(file));
    let _ = root;

    // the header
    let prefix = format!("-- {table}: ");
    if !lines.first().is_some_and(|l| l.starts_with(&prefix) && l.len() > prefix.len()) {
        finding(found, &at, format!("its first line is not `{prefix}` and a sentence"));
    }
    let header: Vec<&str> = lines[..create].iter().filter_map(|l| l.strip_prefix("-- ")).collect();
    let owner_mark = format!("Owner: {}.", owner.id);
    if !header.iter().any(|l| l.contains(&owner_mark)) {
        finding(found, &at, format!("its header does not hold `{owner_mark}`"));
    }

    // one CREATE TABLE, of its table, closed by `);`
    if lines.iter().filter(|l| l.starts_with("CREATE TABLE ")).count() != 1
        || lines[create] != format!("CREATE TABLE {table} (")
    {
        finding(found, &at, format!("it does not hold exactly one CREATE TABLE of {table}"));
    }
    let Some(close) = lines.iter().skip(create).position(|l| l.trim_end() == ");").map(|p| p + create) else {
        finding(found, &at, "its CREATE TABLE is not closed by `);`");
        return;
    };

    // the columns
    let mut columns: Vec<(String, String)> = Vec::new();
    let mut primary: Vec<String> = Vec::new();
    let mut references: Vec<(Option<String>, String)> = Vec::new(); // (the column referring, or None for a table constraint; its target)
    let mut constraints: Vec<String> = Vec::new();
    for (i, line) in lines.iter().enumerate().take(close).skip(create + 1) {
        let (code, comment) = split_comment(line);
        if code.trim_start().starts_with("PRIMARY KEY") {
            primary.push("(table constraint)".into());
        }
        // every reference is to its own namespace or the cortex's, a column's or a table constraint's alike
        let mut rest = code.as_str();
        while let Some(p) = rest.find("REFERENCES ") {
            rest = &rest[p + 11..];
            let target = rest.split_whitespace().next().unwrap_or("").to_string();
            if !target.starts_with(&format!("{ns}.")) && !target.starts_with("cortex.") {
                finding(found, &at, format!("refers to {target}, which is not its own or the cortex's"));
            }
            references.push((column(&code).map(|(c, _)| c), target));
        }
        let Some((col, ty)) = column(&code) else {
            constraints.push(code.trim().trim_end_matches(',').to_string());
            continue;
        };
        if col.contains("__") {
            finding(found, &at, format!("the name {col} holds __"));
        }
        if !TYPES.contains(&ty.as_str()) {
            finding(
                found,
                format!("{at}:{}", i + 1),
                format!("column {col} has the type {ty}, which is none of the eight"),
            );
        }
        match comment {
            Some(c) if c.split_whitespace().next().is_some() => columns.push((col.clone(), c)),
            _ => finding(found, format!("{at}:{}", i + 1), format!("column {col} has no comment")),
        }
        if code.contains("PRIMARY KEY") {
            primary.push(col);
        }
    }
    if of_a_design(&table) {
        design_shape(&at, &columns, &constraints, &references, &lines[close + 1..], &table, found);
    }
    if primary != ["id"] {
        finding(found, &at, "the primary key is not the one column id");
    }
    if stem(file).contains("__") {
        finding(found, &at, format!("the name {table} holds __"));
    }

    // besides it, only its indexes and its comments
    let after: Vec<&str> = lines[close + 1..].iter().copied().filter(|l| !l.trim().is_empty()).collect();
    let mut table_comment: Option<String> = None;
    let mut column_comments: Vec<(String, String)> = Vec::new();
    for l in after {
        let code = split_comment(l).0;
        if code.starts_with("CREATE INDEX ") || code.starts_with("CREATE UNIQUE INDEX ") {
            if !code.contains(&format!(" ON {table} ")) {
                finding(found, &at, format!("an index not on {table}: {code}"));
            }
        } else if let Some(rest) = code.strip_prefix(&format!("COMMENT ON TABLE {table} IS ")) {
            table_comment = literal(rest);
        } else if let Some(rest) = code.strip_prefix(&format!("COMMENT ON COLUMN {table}.")) {
            if let Some((col, lit)) = rest.split_once(" IS ") {
                column_comments.push((col.trim_matches('"').to_string(), literal(lit).unwrap_or_default()));
            }
        } else {
            finding(found, &at, format!("a statement that is not its table's index or comment: {code}"));
        }
    }

    // its comments, in the database's words, are its file's
    let first = lines.first().and_then(|l| l.strip_prefix(&prefix)).unwrap_or("");
    let rest_header: Vec<&str> = header.iter().skip(1).copied().collect();
    let about = spaced(&format!("{first} {}", rest_header.join(" ")).replace(&owner_mark, ""));
    if table_comment.as_deref().map(spaced) != Some(about) {
        finding(found, &at, format!("the database's comment on {table} is not its file's"));
    }
    for (col, comment) in &columns {
        let said = column_comments.iter().find(|(c, _)| c == col).map(|(_, s)| s.as_str());
        if said != Some(comment.as_str()) {
            finding(found, &at, format!("the database's comment on {col} is not its file's"));
        }
    }
}

/// A design's table carries its design: the column design, UNIQUE (design, id), every reference to another design's
/// table by (design, column) to (design, id), and an index on (design, column) for each, so that reading, changing or
/// deleting one design reads that design's rows only (decision work-from-memory).
fn design_shape(
    at: &str,
    columns: &[(String, String)],
    constraints: &[String],
    references: &[(Option<String>, String)],
    after: &[&str],
    table: &str,
    found: &mut Vec<Finding>,
) {
    if !columns.iter().any(|(c, _)| c == "design") {
        finding(found, at, format!("{table} holds a design's rows but has no column design"));
    }
    if !constraints.iter().any(|c| c == "UNIQUE (design, id)") {
        finding(found, at, format!("{table} has no UNIQUE (design, id)"));
    }
    for (col, target) in references {
        if let Some(col) = col
            && col != "design"
            && of_a_design(target)
        {
            finding(found, at, format!("{col} refers to {target} by id alone, not by (design, {col})"));
        }
    }
    for c in constraints {
        let Some(rest) = c.strip_prefix("FOREIGN KEY (") else { continue };
        let cols = rest.split(')').next().unwrap_or("");
        let Some(col) = cols.strip_prefix("design, ") else {
            finding(found, at, format!("a foreign key not led by design: {c}"));
            continue;
        };
        if !c.contains("REFERENCES ") || !c.contains(" (design, id)") {
            finding(found, at, format!("a foreign key not to (design, id): {c}"));
        }
        let indexed = col == "id"
            || after.iter().any(|l| {
                (l.starts_with("CREATE INDEX ") || l.starts_with("CREATE UNIQUE INDEX "))
                    && l.contains(&format!(" ON {table} (design, {col}"))
            });
        if !indexed {
            finding(found, at, format!("no index on {table} (design, {col}) for its foreign key"));
        }
    }
}

fn rule_file(owner: &Owner, file: &Path, at: &str, found: &mut Vec<Finding>) {
    let text = fs::read_to_string(file).unwrap_or_default();
    let rule = stem(file);
    let ns = owner.namespace();
    let view = format!("{ns}.broken_{}", rule.replace('-', "_"));
    let first = text.lines().next().unwrap_or("");
    let ending = format!(" Owner: {ns}.");
    let sentence =
        first.strip_prefix(&format!("-- {rule}: ")).and_then(|s| s.strip_suffix(&ending)).map(str::to_string);
    if sentence.is_none() {
        finding(found, at, format!("its first line is not `-- {rule}: <sentence>{ending}`"));
    }
    let creates: Vec<&str> = text.lines().filter(|l| l.starts_with("CREATE VIEW ")).collect();
    if creates != [format!("CREATE VIEW {view} AS").as_str()] {
        finding(found, at, format!("it does not hold exactly one CREATE VIEW of {view}"));
    }
    let select = text.lines().skip_while(|l| !l.starts_with("CREATE VIEW ")).nth(1).unwrap_or("");
    if !select.starts_with(&format!("SELECT '{rule}' AS rule, ")) || !select.contains(" AS id") {
        finding(
            found,
            at,
            format!("its view does not start `SELECT '{rule}' AS rule, ` and name its second column id"),
        );
    }
    let comment = text.lines().find_map(|l| l.strip_prefix(&format!("COMMENT ON VIEW {view} IS "))).and_then(literal);
    if sentence.is_some() && comment != sentence {
        finding(found, at, "its COMMENT ON VIEW does not hold its sentence".to_string());
    }
}

fn seed_file(root: &Path, owner: &Owner, file: &Path, at: &str, found: &mut Vec<Finding>) {
    let text = fs::read_to_string(file).unwrap_or_default();
    let code: String = text.lines().map(|l| split_comment(l).0).collect::<Vec<_>>().join("\n");
    let ns = owner.namespace();
    let mut tables: Vec<String> = files_in(&root.join(&owner.folder), ".sql")
        .iter()
        .filter(|f| fs::read_to_string(f).is_ok_and(|t| t.lines().any(|l| l.starts_with("CREATE TABLE "))))
        .map(|f| format!("{ns}.{}", stem(f)))
        .collect();
    // an engine declares itself as rows of the cortex's declaration tables (decision declared-options)
    if owner.kind == "engine" {
        tables.extend(DECLARATIONS.iter().map(|t| (*t).to_string()));
    }
    let good = statements(&code).iter().map(|s| s.trim()).filter(|s| !s.is_empty()).all(|stmt| {
        let target = stmt.strip_prefix("INSERT INTO ").and_then(|r| r.split_whitespace().next()).unwrap_or("");
        tables.iter().any(|t| t == target) && spaced(stmt).ends_with("ON CONFLICT (id) DO NOTHING")
    });
    if !good {
        finding(found, at, "a seed writes only new rows of its own tables");
    }
}

/// SQL cut into its statements at each `;` outside a quoted string, so a `;` inside a value cuts nothing.
fn statements(code: &str) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut quoted = false;
    for ch in code.chars() {
        if ch == '\'' {
            quoted = !quoted;
        }
        if ch == ';' && !quoted {
            out.push(String::new());
        } else if let Some(last) = out.last_mut() {
            last.push(ch);
        }
    }
    out
}

fn migrations(root: &Path, owner: &Owner, found: &mut Vec<Finding>) {
    let (numbers, first, bad) = migration_numbers(root, owner);
    if numbers.is_empty() && bad.is_empty() && !first {
        return;
    }
    let contiguous = numbers.iter().enumerate().all(|(i, n)| *n == i as u64 + 2);
    if !bad.is_empty() || !contiguous || (!numbers.is_empty() && !first) {
        let top = numbers.last().copied().unwrap_or(1);
        finding(found, format!("{}/migrations", owner.folder), format!("migrations not numbered 1 to {top}"));
    }
}
