//! What only `SHOW CREATE` says: the facts the catalogs do not give, read from the text of a table, a view, a routine or an
//! account. Every parser works on a copy of the text with the inside of every quoted string and name blanked (same
//! length, so positions carry over), so a keyword inside a comment or a name is never mistaken for one.

use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;

use crate::keys::q;

// --- reading the text ---------------------------------------------------------------------------------------------------------

/// The text with the inside of every quoted string and name blanked with `_`, byte for byte.
pub(crate) fn mask(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut open: Option<char> = None;
    let mut escaped = false;
    for c in text.chars() {
        let blank = "_".repeat(c.len_utf8());
        match open {
            None => {
                if matches!(c, '\'' | '"' | '`') {
                    open = Some(c);
                }
                out.push(c);
            }
            Some(_) if escaped => {
                escaped = false;
                out.push_str(&blank);
            }
            Some(quote) if c == '\\' && quote != '`' => {
                escaped = true;
                out.push_str(&blank);
            }
            Some(quote) if c == quote => {
                open = None;
                out.push(c);
            }
            Some(_) => out.push_str(&blank),
        }
    }
    out
}

/// The index of the `)` that closes the `(` at `open` in a masked text.
pub(crate) fn matching(masked: &str, open: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (i, c) in masked.char_indices().skip_while(|(i, _)| *i < open) {
        match c {
            '(' => depth += 1,
            ')' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
    }
    None
}

/// A name in backticks at the start of `s`, unquoted, and what follows it.
pub(crate) fn read_ident(s: &str) -> Option<(String, &str)> {
    let rest = s.strip_prefix('`')?;
    let mut name = String::new();
    let mut chars = rest.char_indices();
    while let Some((i, c)) = chars.next() {
        if c != '`' {
            name.push(c);
        } else if rest[i + 1..].starts_with('`') {
            name.push('`');
            chars.next();
        } else {
            return Some((name, &rest[i + 1..]));
        }
    }
    None
}

/// A string in single quotes at the start of `s`, with its escapes undone, and what follows it.
pub(crate) fn read_string(s: &str) -> Option<(String, &str)> {
    let rest = s.strip_prefix('\'')?;
    let mut text = String::new();
    let mut chars = rest.char_indices();
    while let Some((i, c)) = chars.next() {
        match c {
            '\'' if rest[i + 1..].starts_with('\'') => {
                text.push('\'');
                chars.next();
            }
            '\'' => return Some((text, &rest[i + 1..])),
            '\\' => match chars.next() {
                Some((_, 'n')) => text.push('\n'),
                Some((_, 'r')) => text.push('\r'),
                Some((_, 't')) => text.push('\t'),
                Some((_, '0')) => text.push('\0'),
                Some((_, other)) => text.push(other),
                None => return None,
            },
            other => text.push(other),
        }
    }
    None
}

/// The value at the start of `s`: a name in backticks, a string, a group in parentheses, or a bare word.
fn read_value<'a>(s: &'a str, masked: &str) -> Option<(String, &'a str)> {
    let s = s.trim_start();
    let offset = masked.len() - masked.trim_start().len();
    let _ = offset;
    if s.starts_with('`') {
        read_ident(s)
    } else if s.starts_with('\'') {
        read_string(s)
    } else if s.starts_with('(') {
        let close = matching(&mask(s), 0)?;
        Some((s[1..close].to_string(), &s[close + 1..]))
    } else {
        let end = s
            .find(|c: char| c.is_whitespace() || c == ',' || c == ')')
            .unwrap_or(s.len());
        (end > 0).then(|| (s[..end].to_string(), &s[end..]))
    }
}

/// The value written after a keyword (`KEY = value`, `KEY value`), found on the masked text and read from the original.
fn value_after(original: &str, masked: &str, key: &str) -> Option<String> {
    let pattern = Regex::new(&format!(r"\b{}\b\s*=?\s*", regex::escape(key))).ok()?;
    let found = pattern.find(masked)?;
    read_value(&original[found.end()..], &masked[found.end()..]).map(|(value, _)| value)
}

static COLUMN_FORMAT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\bCOLUMN_FORMAT (FIXED|DYNAMIC|COMPRESSED|DEFAULT)\b").expect("a fixed pattern"));
static STORAGE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\bSTORAGE (DISK|MEMORY)\b").expect("a fixed pattern"));
static USING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\bUSING (BTREE|HASH)\b").expect("a fixed pattern"));
static KEY_BLOCK_SIZE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\bKEY_BLOCK_SIZE\s*=\s*(\d+)").expect("a fixed pattern"));
static ALGORITHM: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\bPARTITION BY (?:LINEAR )?KEY ALGORITHM = (\d)").expect("a fixed pattern"));
static SUB_ALGORITHM: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\bSUBPARTITION BY (?:LINEAR )?KEY ALGORITHM = (\d)").expect("a fixed pattern"));
static INDEX_HEAD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^\s*(PRIMARY KEY|UNIQUE KEY|FULLTEXT KEY|SPATIAL KEY|KEY)\s*(`_*`)?\s*\(").expect("a fixed pattern")
});

// --- a table ------------------------------------------------------------------------------------------------------------------

/// What `SHOW CREATE TABLE` says of a column beyond the catalog.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ColumnShow {
    /// The expression of a generated column, as written (the catalog's copy escapes its quotes on 8.0).
    pub generated_expression: Option<String>,
    /// `COLUMN_FORMAT`.
    pub column_format: Option<String>,
    /// `STORAGE`.
    pub storage: Option<String>,
    /// Percona: the dictionary a compressed column uses.
    pub compression_dictionary: Option<String>,
    /// `ENGINE_ATTRIBUTE`.
    pub engine_attribute: Option<String>,
    /// `SECONDARY_ENGINE_ATTRIBUTE`.
    pub secondary_engine_attribute: Option<String>,
}

/// What `SHOW CREATE TABLE` says of an index beyond the catalog.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct IndexShow {
    /// The index's name; `PRIMARY` for the primary key.
    pub name: String,
    /// `USING BTREE` or `USING HASH`, where written.
    pub method: Option<String>,
    /// `KEY_BLOCK_SIZE`, where written.
    pub key_block_size: Option<i64>,
    /// `WITH PARSER`, where written.
    pub parser: Option<String>,
    /// `ENGINE_ATTRIBUTE`.
    pub engine_attribute: Option<String>,
    /// `SECONDARY_ENGINE_ATTRIBUTE`.
    pub secondary_engine_attribute: Option<String>,
}

/// What the options line of `SHOW CREATE TABLE` says beyond the catalog.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TableOptions {
    /// `AUTO_INCREMENT`.
    pub auto_increment: Option<i64>,
    /// `TABLESPACE`.
    pub tablespace: Option<String>,
    /// A MERGE table's tables, in order.
    pub union: Vec<String>,
    /// `INSERT_METHOD`.
    pub insert_method: Option<String>,
    /// A FEDERATED table's `CONNECTION`.
    pub connection: Option<String>,
    /// `DATA DIRECTORY`.
    pub data_directory: Option<String>,
    /// `INDEX DIRECTORY`.
    pub index_directory: Option<String>,
    /// `STORAGE`.
    pub storage: Option<String>,
    /// `ENGINE_ATTRIBUTE`.
    pub engine_attribute: Option<String>,
    /// `SECONDARY_ENGINE`.
    pub secondary_engine: Option<String>,
    /// `SECONDARY_ENGINE_ATTRIBUTE`.
    pub secondary_engine_attribute: Option<String>,
}

/// What a partition's or subpartition's own clause writes, where it writes it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PartitionShow {
    /// `ENGINE`.
    pub engine: Option<String>,
    /// `DATA DIRECTORY`.
    pub data_directory: Option<String>,
    /// `INDEX DIRECTORY`.
    pub index_directory: Option<String>,
    /// `MAX_ROWS`.
    pub max_rows: Option<i64>,
    /// `MIN_ROWS`.
    pub min_rows: Option<i64>,
    /// `TABLESPACE`.
    pub tablespace: Option<String>,
}

/// What `SHOW CREATE TABLE` says that the catalogs do not.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TableShow {
    /// Each listed partition's and subpartition's own options, by name.
    pub partition_options: HashMap<String, PartitionShow>,
    /// The table's options.
    pub options: TableOptions,
    /// Each column's, by name.
    pub columns: HashMap<String, ColumnShow>,
    /// Each index, in the order the statement lists them.
    pub indexes: Vec<IndexShow>,
    /// Foreign keys and checks by name, in the order the statement lists them.
    pub constraints: Vec<String>,
    /// `ALGORITHM` of a KEY partitioning.
    pub key_algorithm: Option<i64>,
    /// `ALGORITHM` of a KEY subpartitioning.
    pub sub_key_algorithm: Option<i64>,
    /// Whether the partitions are written one by one (otherwise `PARTITIONS n`).
    pub partitions_listed: bool,
    /// Whether the subpartitions are written one by one.
    pub subpartitions_listed: bool,
}

/// Reads a `SHOW CREATE TABLE`.
pub fn parse_table(create: &str) -> TableShow {
    let masked = mask(create);
    let split = masked.rfind("\n)").unwrap_or(masked.len());
    let (body, body_masked) = (&create[..split], &masked[..split]);
    let mut show = TableShow::default();
    for (line, line_masked) in body.lines().zip(body_masked.lines()).skip(1) {
        let line = line.trim_end_matches(',');
        let line_masked = line_masked.trim_end_matches(',');
        if let Some(rest) = line.strip_prefix("  `") {
            if let Some((name, _)) = read_ident(&format!("`{rest}")) {
                show.columns.insert(name, column(line, line_masked));
            }
        } else if let Some(head) = INDEX_HEAD.captures(line_masked) {
            show.indexes.push(index(line, line_masked, &head));
        } else if let Some(rest) = line.trim_start().strip_prefix("CONSTRAINT ")
            && let Some((name, _)) = read_ident(rest)
        {
            show.constraints.push(name);
        }
    }
    // the tail starts after the closing parenthesis: its first line holds the options
    let after = (split + "\n)".len()).min(create.len());
    let tail = &create[after..];
    let tail_masked = &masked[after..];
    show.options = options(tail, tail_masked);
    let cut = tail_masked.find('\n').unwrap_or(tail_masked.len());
    let partitioned = &tail_masked[cut..];
    show.partition_options = partition_options(&tail[cut..], partitioned);
    show.key_algorithm = ALGORITHM.captures(partitioned).and_then(|c| c[1].parse().ok());
    show.sub_key_algorithm = SUB_ALGORITHM.captures(partitioned).and_then(|c| c[1].parse().ok());
    show.partitions_listed = partitioned.contains("(PARTITION ");
    show.subpartitions_listed = partitioned.contains("SUBPARTITION `");
    show
}

static PARTITION_HEAD: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b(?:SUB)?PARTITION `_*`").expect("a fixed pattern"));

/// The options each `PARTITION `p`` and `SUBPARTITION `s`` clause writes, by the partition's name.
fn partition_options(text: &str, masked: &str) -> HashMap<String, PartitionShow> {
    let heads: Vec<_> = PARTITION_HEAD.find_iter(masked).collect();
    let mut found = HashMap::new();
    for (i, head) in heads.iter().enumerate() {
        let end = heads.get(i + 1).map_or(masked.len(), |next| next.start());
        let Some(tick) = head.as_str().find('`') else { continue };
        let Some((name, _)) = read_ident(&text[head.start() + tick..]) else {
            continue;
        };
        let (clause, clause_masked) = (&text[head.end()..end], &masked[head.end()..end]);
        let number = |key: &str| value_after(clause, clause_masked, key).and_then(|v| v.parse().ok());
        found.insert(
            name,
            PartitionShow {
                engine: value_after(clause, clause_masked, "ENGINE"),
                data_directory: value_after(clause, clause_masked, "DATA DIRECTORY"),
                index_directory: value_after(clause, clause_masked, "INDEX DIRECTORY"),
                max_rows: number("MAX_ROWS"),
                min_rows: number("MIN_ROWS"),
                tablespace: value_after(clause, clause_masked, "TABLESPACE"),
            },
        );
    }
    found
}

fn column(line: &str, masked: &str) -> ColumnShow {
    let generated = masked.find(" GENERATED ALWAYS AS (").and_then(|at| {
        let open = at + " GENERATED ALWAYS AS ".len();
        matching(masked, open).map(|close| line[open + 1..close].to_string())
    });
    let dictionary = masked
        .find(" WITH COMPRESSION_DICTIONARY ")
        .and_then(|at| read_ident(&line[at + " WITH COMPRESSION_DICTIONARY ".len()..]).map(|(name, _)| name));
    ColumnShow {
        generated_expression: generated,
        column_format: COLUMN_FORMAT.captures(masked).map(|c| c[1].to_string()),
        storage: STORAGE.captures(masked).map(|c| c[1].to_string()),
        compression_dictionary: dictionary,
        engine_attribute: value_after(line, masked, "ENGINE_ATTRIBUTE"),
        secondary_engine_attribute: value_after(line, masked, "SECONDARY_ENGINE_ATTRIBUTE"),
    }
}

fn index(line: &str, masked: &str, head: &regex::Captures<'_>) -> IndexShow {
    let name = if &head[1] == "PRIMARY KEY" {
        "PRIMARY".to_string()
    } else {
        head.get(2)
            .and_then(|m| read_ident(&line[m.start()..]).map(|(n, _)| n))
            .unwrap_or_default()
    };
    let open = head.get(0).map_or(0, |m| m.end() - 1);
    let clauses_at = matching(masked, open).map_or(masked.len(), |close| close + 1);
    let (rest, rest_masked) = (&line[clauses_at..], &masked[clauses_at..]);
    IndexShow {
        name,
        method: USING.captures(rest_masked).map(|c| c[1].to_string()),
        key_block_size: KEY_BLOCK_SIZE.captures(rest_masked).and_then(|c| c[1].parse().ok()),
        parser: rest_masked
            .find("WITH PARSER ")
            .and_then(|at| read_ident(&rest[at + "WITH PARSER ".len()..]).map(|(n, _)| n)),
        engine_attribute: value_after(rest, rest_masked, "ENGINE_ATTRIBUTE"),
        secondary_engine_attribute: value_after(rest, rest_masked, "SECONDARY_ENGINE_ATTRIBUTE"),
    }
}

fn options(tail: &str, masked: &str) -> TableOptions {
    // the options are on the first line of the tail; the partitioning, if any, follows it
    let end = masked.find('\n').unwrap_or(masked.len());
    let (line, line_masked) = (&tail[..end], &masked[..end]);
    let tablespace = line_masked
        .find("TABLESPACE ")
        .and_then(|at| read_ident(&line[at + "TABLESPACE ".len()..]).map(|(name, _)| name));
    let union = value_after(line, line_masked, "UNION")
        .map(|list| {
            list.split(',')
                .filter_map(|n| read_ident(n.trim()).map(|(name, _)| name))
                .collect()
        })
        .unwrap_or_default();
    TableOptions {
        auto_increment: value_after(line, line_masked, "AUTO_INCREMENT").and_then(|v| v.parse().ok()),
        tablespace,
        union,
        insert_method: value_after(line, line_masked, "INSERT_METHOD"),
        connection: value_after(line, line_masked, "CONNECTION"),
        data_directory: value_after(line, line_masked, "DATA DIRECTORY"),
        index_directory: value_after(line, line_masked, "INDEX DIRECTORY"),
        storage: STORAGE.captures(line_masked).map(|c| c[1].to_string()),
        engine_attribute: value_after(line, line_masked, "ENGINE_ATTRIBUTE"),
        secondary_engine: value_after(line, line_masked, "SECONDARY_ENGINE"),
        secondary_engine_attribute: value_after(line, line_masked, "SECONDARY_ENGINE_ATTRIBUTE"),
    }
}

// --- a view -------------------------------------------------------------------------------------------------------------------

/// What `SHOW CREATE VIEW` says that the catalogs do not.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ViewShow {
    /// `ALGORITHM`.
    pub algorithm: String,
    /// The query after `AS`, without its `WITH ... CHECK OPTION`, written as from inside the view's own database.
    pub definition: String,
    /// The `database`.`name` pairs the query names as the server wrote it, outside strings, in the order found: the
    /// tables and views a view reads, where the server does not list them (5.7).
    pub references: Vec<(String, String)>,
    /// Whether it is a JSON duality view (9.7), which an import refuses.
    pub duality: bool,
}

static VIEW_HEAD: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r" VIEW (?:`(?:[^`]|``)*`\.)?`(?:[^`]|``)*` AS ").expect("a fixed pattern"));
static VIEW_ALGORITHM: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^CREATE ALGORITHM=(\w+)").expect("a fixed pattern"));

/// Reads a `SHOW CREATE VIEW` of a view of `database`.
pub fn parse_view(create: &str, database: &str) -> Result<ViewShow, String> {
    let head = VIEW_HEAD
        .find(create)
        .ok_or_else(|| "no AS after the view's name".to_string())?;
    let mut definition = create[head.end()..].to_string();
    for option in [" WITH CASCADED CHECK OPTION", " WITH LOCAL CHECK OPTION"] {
        if let Some(stripped) = definition.strip_suffix(option) {
            definition = stripped.to_string();
        }
    }
    Ok(ViewShow {
        algorithm: VIEW_ALGORITHM
            .captures(create)
            .map_or_else(|| "UNDEFINED".to_string(), |c| c[1].to_string()),
        references: qualified_pairs(&definition),
        definition: unqualify(&definition, database),
        duality: create[..head.start()].contains("DUALITY"),
    })
}

/// Every `` `a`.`b` `` of a query outside its strings: the first two names of each dotted run of names.
pub(crate) fn qualified_pairs(query: &str) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    let mut rest = query;
    while let Some(c) = rest.chars().next() {
        match c {
            '`' => match read_ident(rest) {
                Some((first, after)) => {
                    rest = after;
                    if let Some(second) = after.strip_prefix('.')
                        && let Some((second, after_second)) = read_ident(second)
                    {
                        pairs.push((first, second));
                        rest = after_second;
                        // a third name after a dot is a column of the pair, not another pair
                        while let Some(more) = rest.strip_prefix('.') {
                            match read_ident(more) {
                                Some((_, after_more)) => rest = after_more,
                                None => break,
                            }
                        }
                    }
                }
                None => break,
            },
            '\'' | '"' => rest = &rest[string_end(rest, c)..],
            _ => rest = &rest[c.len_utf8()..],
        }
    }
    pairs
}

/// A query with every `` `database`. `` that qualifies a name outside a string removed: read from outside its database
/// the server qualifies every name, and the definition written from inside it does not.
pub(crate) fn unqualify(query: &str, database: &str) -> String {
    let qualifier = format!("{}.", q(database));
    let mut out = String::with_capacity(query.len());
    let mut rest = query;
    while let Some(c) = rest.chars().next() {
        match c {
            '`' if rest.starts_with(&qualifier) => rest = &rest[qualifier.len()..],
            '`' => match read_ident(rest) {
                Some((_, after)) => {
                    out.push_str(&rest[..rest.len() - after.len()]);
                    rest = after;
                }
                None => break,
            },
            '\'' | '"' => {
                let end = string_end(rest, c);
                out.push_str(&rest[..end]);
                rest = &rest[end..];
            }
            _ => {
                out.push(c);
                rest = &rest[c.len_utf8()..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// The byte length of the string that opens at the start of `s` with `quote`, quotes and escapes included.
fn string_end(s: &str, quote: char) -> usize {
    let mut chars = s.char_indices().skip(1);
    while let Some((i, c)) = chars.next() {
        if c == '\\' {
            chars.next();
        } else if c == quote {
            if s[i + 1..].starts_with(quote) {
                chars.next();
            } else {
                return i + 1;
            }
        }
    }
    s.len()
}

// --- a routine ----------------------------------------------------------------------------------------------------------------

/// What `SHOW CREATE PROCEDURE` or `FUNCTION` says that the catalogs do not.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoutineShow {
    /// The parameter list exactly as written, between the parentheses.
    pub parameter_list: String,
    /// A function's `RETURNS` type as written.
    pub returns: Option<String>,
    /// The body, after the characteristics, exactly as the server writes it.
    pub body: String,
}

static CHARACTERISTIC: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^    (DETERMINISTIC|NOT DETERMINISTIC|CONTAINS SQL|NO SQL|READS SQL DATA|MODIFIES SQL DATA|SQL SECURITY \w+|COMMENT '|LANGUAGE \w+)",
    )
    .expect("a fixed pattern")
});

/// Reads a `SHOW CREATE PROCEDURE` (`kind` is `PROCEDURE`) or `FUNCTION` of a routine called `name`.
pub fn parse_routine(create: &str, kind: &str, name: &str) -> Result<RoutineShow, String> {
    let head = format!("{kind} {}(", q(name));
    let at = create
        .find(&head)
        .ok_or_else(|| format!("no {kind} {name} in its statement"))?;
    let open = at + head.len() - 1;
    let masked = mask(create);
    let close = matching(&masked, open).ok_or_else(|| "the parameter list is not closed".to_string())?;
    let parameter_list = create[open + 1..close].to_string();
    let mut rest = &create[close + 1..];
    let mut returns = None;
    if kind == "FUNCTION" {
        let line = rest
            .strip_prefix(" RETURNS ")
            .ok_or_else(|| "a function without RETURNS".to_string())?;
        let end = line.find('\n').ok_or_else(|| "a function without a body".to_string())?;
        returns = Some(line[..end].to_string());
        rest = &line[end + 1..];
    } else {
        rest = rest.trim_start_matches('\n');
    }
    let lines: Vec<&str> = rest.split('\n').collect();
    let characteristics = lines.iter().take_while(|l| CHARACTERISTIC.is_match(l)).count();
    Ok(RoutineShow {
        parameter_list,
        returns,
        body: lines[characteristics..].join("\n"),
    })
}

// --- an account ---------------------------------------------------------------------------------------------------------------

/// What `SHOW CREATE USER` says of an account: how it signs in and its limits and policies, never its password or hash.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct UserShow {
    /// `IDENTIFIED WITH`.
    pub auth_plugin: Option<String>,
    /// `REQUIRE`: `NONE`, `SSL`, `X509` or `SPECIFIED`.
    pub ssl_type: String,
    /// `REQUIRE CIPHER`.
    pub ssl_cipher: Option<String>,
    /// `REQUIRE ISSUER`.
    pub x509_issuer: Option<String>,
    /// `REQUIRE SUBJECT`.
    pub x509_subject: Option<String>,
    /// `MAX_QUERIES_PER_HOUR`.
    pub max_queries_per_hour: i64,
    /// `MAX_UPDATES_PER_HOUR`.
    pub max_updates_per_hour: i64,
    /// `MAX_CONNECTIONS_PER_HOUR`.
    pub max_connections_per_hour: i64,
    /// `MAX_USER_CONNECTIONS`.
    pub max_user_connections: i64,
    /// `PASSWORD EXPIRE`: empty when written bare, none when not written.
    pub password_expire: Option<String>,
    /// `PASSWORD HISTORY`.
    pub password_history: Option<String>,
    /// `PASSWORD REUSE INTERVAL`.
    pub password_reuse_interval: Option<String>,
    /// `PASSWORD REQUIRE CURRENT`.
    pub password_require_current: Option<String>,
    /// `FAILED_LOGIN_ATTEMPTS`.
    pub failed_login_attempts: Option<i64>,
    /// `PASSWORD_LOCK_TIME`.
    pub password_lock_time: Option<String>,
    /// `ACCOUNT LOCK`.
    pub locked: bool,
    /// `ATTRIBUTE`, as its JSON text.
    pub attributes: Option<String>,
    /// Whether the account has a password (an `AS` hash): what tells a role from an account.
    pub has_password: bool,
}

static EXPIRE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r" PASSWORD EXPIRE( DEFAULT| NEVER| INTERVAL \d+ DAY)?").expect("a fixed pattern"));
static HISTORY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r" PASSWORD HISTORY (DEFAULT|\d+)").expect("a fixed pattern"));
static REUSE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r" PASSWORD REUSE INTERVAL (DEFAULT|\d+ DAY)").expect("a fixed pattern"));
static REQUIRE_CURRENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r" PASSWORD REQUIRE CURRENT( DEFAULT| OPTIONAL)?").expect("a fixed pattern"));
static LOCK_TIME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r" PASSWORD_LOCK_TIME (\d+|UNBOUNDED)").expect("a fixed pattern"));
static FAILED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r" FAILED_LOGIN_ATTEMPTS (\d+)").expect("a fixed pattern"));

/// Reads a `SHOW CREATE USER`.
pub fn parse_user(create: &str) -> UserShow {
    let masked = mask(create);
    let quoted = |keyword: &str| {
        masked
            .find(keyword)
            .and_then(|at| read_string(&create[at + keyword.len()..]).map(|(value, _)| value))
    };
    let limit = |name: &str| {
        Regex::new(&format!(r"\b{name} (\d+)"))
            .ok()
            .and_then(|r| r.captures(&masked).and_then(|c| c[1].parse().ok()))
            .unwrap_or(0)
    };
    let ssl_type = if masked.contains(" REQUIRE SSL") {
        "SSL"
    } else if masked.contains(" REQUIRE X509") {
        "X509"
    } else if masked.contains(" REQUIRE ISSUER")
        || masked.contains(" REQUIRE SUBJECT")
        || masked.contains(" REQUIRE CIPHER")
    {
        "SPECIFIED"
    } else {
        "NONE"
    };
    UserShow {
        auth_plugin: quoted(" IDENTIFIED WITH "),
        ssl_type: ssl_type.to_string(),
        ssl_cipher: quoted(" CIPHER "),
        x509_issuer: quoted(" ISSUER "),
        x509_subject: quoted(" SUBJECT "),
        max_queries_per_hour: limit("MAX_QUERIES_PER_HOUR"),
        max_updates_per_hour: limit("MAX_UPDATES_PER_HOUR"),
        max_connections_per_hour: limit("MAX_CONNECTIONS_PER_HOUR"),
        max_user_connections: limit("MAX_USER_CONNECTIONS"),
        password_expire: EXPIRE
            .captures(&masked)
            .map(|c| c.get(1).map_or(String::new(), |m| m.as_str().trim().to_string())),
        password_history: HISTORY.captures(&masked).map(|c| c[1].to_string()),
        password_reuse_interval: REUSE.captures(&masked).map(|c| c[1].to_string()),
        password_require_current: REQUIRE_CURRENT
            .captures(&masked)
            .and_then(|c| c.get(1).map(|m| m.as_str().trim().to_string())),
        failed_login_attempts: FAILED.captures(&masked).and_then(|c| c[1].parse().ok()),
        password_lock_time: LOCK_TIME.captures(&masked).map(|c| c[1].to_string()),
        locked: masked.contains(" ACCOUNT LOCK"),
        attributes: quoted(" ATTRIBUTE "),
        has_password: masked.contains(" AS '"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_keyword_inside_a_comment_is_not_a_keyword() {
        let create = "CREATE TABLE `t` (\n  `a` int DEFAULT NULL COMMENT 'COLUMN_FORMAT FIXED, STORAGE DISK',\n  `b` int GENERATED ALWAYS AS ((`a` + 1)) STORED\n) ENGINE=InnoDB AUTO_INCREMENT=7 COMMENT='UNION=(`x`)'";
        let show = parse_table(create);
        assert_eq!(show.columns["a"], ColumnShow::default());
        assert_eq!(show.columns["b"].generated_expression.as_deref(), Some("(`a` + 1)"));
        assert_eq!(show.options.auto_increment, Some(7));
        assert!(show.options.union.is_empty());
    }

    #[test]
    fn a_table_says_its_indexes_in_order_with_their_clauses() {
        let create = "CREATE TABLE `t` (\n  `id` int NOT NULL,\n  `n` varchar(10) DEFAULT NULL,\n  PRIMARY KEY (`id`) USING BTREE,\n  UNIQUE KEY `uq` (`n`(5)) KEY_BLOCK_SIZE=8 COMMENT 'a (b)',\n  FULLTEXT KEY `ft` (`n`) /*!50100 WITH PARSER `ngram` */,\n  CONSTRAINT `fk` FOREIGN KEY (`id`) REFERENCES `u` (`id`)\n) ENGINE=InnoDB";
        let show = parse_table(create);
        let names: Vec<_> = show.indexes.iter().map(|i| i.name.as_str()).collect();
        assert_eq!(names, ["PRIMARY", "uq", "ft"]);
        assert_eq!(show.indexes[0].method.as_deref(), Some("BTREE"));
        assert_eq!(show.indexes[1].key_block_size, Some(8));
        assert_eq!(show.indexes[2].parser.as_deref(), Some("ngram"));
        assert_eq!(show.constraints, ["fk"]);
    }

    #[test]
    fn the_options_line_gives_a_merge_tables_tables_and_a_tablespace() {
        let create = "CREATE TABLE `m` (\n  `id` int NOT NULL\n) ENGINE=MRG_MyISAM DEFAULT CHARSET=utf8mb4 INSERT_METHOD=LAST UNION=(`a`,`b``c`)";
        let options = parse_table(create).options;
        assert_eq!(options.union, ["a", "b`c"]);
        assert_eq!(options.insert_method.as_deref(), Some("LAST"));
        let create = "CREATE TABLE `i` (\n  `id` int NOT NULL\n) /*!50100 TABLESPACE `ts_shop` */ ENGINE=InnoDB";
        assert_eq!(parse_table(create).options.tablespace.as_deref(), Some("ts_shop"));
    }

    #[test]
    fn partitions_are_listed_or_counted() {
        let listed = "CREATE TABLE `s` (\n  `id` int NOT NULL\n) ENGINE=InnoDB\n/*!50100 PARTITION BY KEY ALGORITHM = 2 (`id`)\n(PARTITION `p0` ENGINE = InnoDB) */";
        let show = parse_table(listed);
        assert!(show.partitions_listed);
        assert_eq!(show.key_algorithm, Some(2));
        let counted = "CREATE TABLE `s` (\n  `id` int NOT NULL\n) ENGINE=InnoDB\n/*!50100 PARTITION BY HASH (`id`)\nPARTITIONS 4 */";
        assert!(!parse_table(counted).partitions_listed);
    }

    #[test]
    fn a_view_is_written_as_from_inside_its_own_database() {
        let create = "CREATE ALGORITHM=MERGE DEFINER=`root`@`%` SQL SECURITY INVOKER VIEW `shop`.`v` AS select `shop`.`c`.`id` AS `id`,'`shop`.`x`' AS `lit` from `shop`.`c` where (`shop`.`c`.`status` = 'active') WITH CASCADED CHECK OPTION";
        let view = parse_view(create, "shop").unwrap();
        assert_eq!(view.algorithm, "MERGE");
        assert_eq!(
            view.definition,
            "select `c`.`id` AS `id`,'`shop`.`x`' AS `lit` from `c` where (`c`.`status` = 'active')"
        );
    }

    #[test]
    fn each_listed_partition_says_its_own_options() {
        let create = "CREATE TABLE `s` (\n  `id` int NOT NULL\n) ENGINE=InnoDB\n/*!50100 PARTITION BY RANGE (`id`)\nSUBPARTITION BY HASH (`id`)\n(PARTITION `p0` VALUES LESS THAN (10)\n (SUBPARTITION `p0a` ENGINE = InnoDB,\n  SUBPARTITION `p0b` MAX_ROWS = 50 ENGINE = InnoDB),\n PARTITION `p1` VALUES LESS THAN MAXVALUE\n (SUBPARTITION `p1a` ENGINE = InnoDB)) */";
        let show = parse_table(create);
        assert!(show.partitions_listed && show.subpartitions_listed);
        assert_eq!(show.partition_options["p0a"].engine.as_deref(), Some("InnoDB"));
        assert_eq!(show.partition_options["p0b"].max_rows, Some(50));
        assert_eq!(show.partition_options.len(), 5);
    }

    #[test]
    fn a_view_names_the_tables_it_reads_outside_its_strings() {
        let create = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `shop`.`v` AS select `shop`.`c`.`id` AS `id`,'`x`.`y`' AS `lit` from (`shop`.`c` join `other`.`d` on((`shop`.`c`.`id` = `other`.`d`.`c_id`)))";
        let view = parse_view(create, "shop").unwrap();
        let mut pairs = view.references.clone();
        pairs.sort();
        pairs.dedup();
        assert_eq!(
            pairs,
            [
                ("other".to_string(), "d".to_string()),
                ("shop".to_string(), "c".to_string())
            ]
        );
        assert!(!view.duality);
    }

    #[test]
    fn a_routine_gives_its_parameters_its_return_type_and_its_body() {
        let create = "CREATE DEFINER=`root`@`%` FUNCTION `spent`(p_customer INT UNSIGNED) RETURNS decimal(14,2)\n    DETERMINISTIC\n    READS SQL DATA\n    SQL SECURITY INVOKER\nBEGIN\n  RETURN (SELECT 1);\nEND";
        let routine = parse_routine(create, "FUNCTION", "spent").unwrap();
        assert_eq!(routine.parameter_list, "p_customer INT UNSIGNED");
        assert_eq!(routine.returns.as_deref(), Some("decimal(14,2)"));
        assert_eq!(routine.body, "BEGIN\n  RETURN (SELECT 1);\nEND");
        let create = "CREATE DEFINER=`root`@`%` PROCEDURE `p`(IN a decimal(14,2), OUT b bigint)\n    MODIFIES SQL DATA\n    COMMENT 'it (is)'\nBEGIN\nEND";
        let routine = parse_routine(create, "PROCEDURE", "p").unwrap();
        assert_eq!(routine.parameter_list, "IN a decimal(14,2), OUT b bigint");
        assert_eq!(routine.returns, None);
        assert_eq!(routine.body, "BEGIN\nEND");
    }

    #[test]
    fn an_account_says_how_it_signs_in_and_never_its_password() {
        let create = "CREATE USER `app`@`%` IDENTIFIED WITH 'caching_sha2_password' AS '$A$005$abc' REQUIRE SSL WITH MAX_QUERIES_PER_HOUR 5000 MAX_USER_CONNECTIONS 20 PASSWORD EXPIRE INTERVAL 90 DAY ACCOUNT UNLOCK PASSWORD HISTORY DEFAULT PASSWORD REUSE INTERVAL DEFAULT PASSWORD REQUIRE CURRENT DEFAULT ATTRIBUTE '{\\\"team\\\": \\\"shop\\\"}'";
        let user = parse_user(create);
        assert_eq!(user.auth_plugin.as_deref(), Some("caching_sha2_password"));
        assert_eq!(user.ssl_type, "SSL");
        assert_eq!(
            (
                user.max_queries_per_hour,
                user.max_user_connections,
                user.max_updates_per_hour
            ),
            (5000, 20, 0)
        );
        assert_eq!(user.password_expire.as_deref(), Some("INTERVAL 90 DAY"));
        assert_eq!(user.password_history.as_deref(), Some("DEFAULT"));
        assert!(!user.locked);
        assert!(user.has_password);
        assert_eq!(user.attributes.as_deref(), Some("{\"team\": \"shop\"}"));
        let role = parse_user(
            "CREATE USER `reader`@`%` IDENTIFIED WITH 'caching_sha2_password' REQUIRE NONE PASSWORD EXPIRE ACCOUNT LOCK",
        );
        assert!(role.locked && !role.has_password);
        assert_eq!(role.password_expire.as_deref(), Some(""));
    }
}
