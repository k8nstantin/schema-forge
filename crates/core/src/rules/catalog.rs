//! The built-in rules: checks, the packs they make up (root rules), and the goals that link packs for you.

use std::sync::LazyLock;

use serde::Serialize;

use super::compat::{MAPS, TypeMap};
use crate::Target;

/// How hard a rule holds: a `must` is refused by the agent's operations, a `should` is listed as a finding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Strength {
    Must,
    Should,
}

/// Where a rule applies, the first way the catalog is sorted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Lane {
    /// Every database: nothing without a key, one type per kind of value.
    Shared,
    Mysql,
    Postgres,
    Iceberg,
    /// Between two databases: compatibility and change data capture.
    Between,
}

/// A rule: a check, or a pack made of rules (any depth; a rule may sit in several packs).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Rule {
    pub id: String,
    pub title: String,
    pub strength: Strength,
    /// Why it matters, in a sentence.
    pub why: String,
    /// The rules it is made of; empty for a check.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub rules: Vec<String>,
    /// Where it applies: every database, one of them, or between two.
    pub lane: Lane,
    /// What it is about: `keys`, `types`, `naming`, `documentation`, `normalization`, `history`, `storage`, `cdc`,
    /// `compatibility`, `basics`.
    pub topic: &'static str,
    /// The targets it checks; empty for every target.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub targets: Vec<Target>,
}

/// What a schema has to do: the packs that get it there, and what must be set outside the schema.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Goal {
    pub id: &'static str,
    pub title: &'static str,
    pub about: &'static str,
    /// The packs it links, by the schema's target.
    pub packs: Vec<(Target, Vec<&'static str>)>,
    /// What has to be set outside the schema, by the database it concerns.
    pub outside: Vec<(Target, Vec<(&'static str, &'static str)>)>,
}

/// Every built-in rule, goal and type map.
#[derive(Debug, Serialize)]
pub struct Catalog {
    pub rules: Vec<Rule>,
    pub goals: Vec<Goal>,
    pub maps: &'static [TypeMap],
}

impl Catalog {
    /// The rule called `id`.
    #[must_use]
    pub fn rule(&self, id: &str) -> Option<&Rule> {
        self.rules.iter().find(|r| r.id == id)
    }

    /// The checks `id` is made of, itself if it is one; each once, in order.
    #[must_use]
    pub fn checks(&self, id: &str) -> Vec<&str> {
        let mut out = Vec::new();
        let mut seen = Vec::new();
        self.walk(id, &mut seen, &mut out);
        out
    }

    fn walk<'a>(&'a self, id: &str, seen: &mut Vec<&'a str>, out: &mut Vec<&'a str>) {
        let Some(rule) = self.rule(id) else { return };
        if seen.contains(&rule.id.as_str()) {
            return;
        }
        seen.push(&rule.id);
        if rule.rules.is_empty() {
            out.push(&rule.id);
        }
        for child in &rule.rules {
            self.walk(child, seen, out);
        }
    }

    /// Whether `inner` is `outer` or sits anywhere inside it.
    #[must_use]
    pub fn contains(&self, outer: &str, inner: &str) -> bool {
        if outer == inner {
            return true;
        }
        let mut seen = Vec::new();
        self.reaches(outer, inner, &mut seen)
    }

    fn reaches<'a>(&'a self, outer: &str, inner: &str, seen: &mut Vec<&'a str>) -> bool {
        let Some(rule) = self.rule(outer) else { return false };
        if seen.contains(&rule.id.as_str()) {
            return false;
        }
        seen.push(&rule.id);
        rule.rules.iter().any(|c| c == inner || self.reaches(c, inner, seen))
    }
}

/// The built-in catalog.
pub fn catalog() -> &'static Catalog {
    static CATALOG: LazyLock<Catalog> = LazyLock::new(build);
    &CATALOG
}

fn check(id: &str, title: &str, strength: Strength, why: &str, targets: &[Target]) -> Rule {
    Rule {
        id: id.to_string(),
        title: title.to_string(),
        strength,
        why: why.to_string(),
        rules: Vec::new(),
        lane: Lane::Shared,
        topic: "",
        targets: targets.to_vec(),
    }
}

fn pack(id: &str, title: &str, why: &str, rules: &[&str]) -> Rule {
    Rule {
        id: id.to_string(),
        title: title.to_string(),
        strength: Strength::Should,
        why: why.to_string(),
        rules: rules.iter().map(ToString::to_string).collect(),
        lane: Lane::Shared,
        topic: "",
        targets: Vec::new(),
    }
}

const ICEBERG: &[Target] = &[Target::Iceberg];
const SOURCES: &[Target] = &[Target::Mysql, Target::Postgres];
const MYSQL: &[Target] = &[Target::Mysql];
const POSTGRES: &[Target] = &[Target::Postgres];

fn target_title(t: Target) -> &'static str {
    match t {
        Target::Mysql => "MySQL",
        Target::Postgres => "PostgreSQL",
        Target::Iceberg => "Iceberg",
    }
}

fn build() -> Catalog {
    use Strength::{Must, Should};
    let mut rules = vec![
        pack(
            "types",
            "Data types",
            "One type per kind of value, so every table stores the same thing the same way.",
            &["types.time", "types.drift", "types.money"],
        ),
        check(
            "types.time",
            "Times are timestamps, not strings",
            Should,
            "A time kept as text cannot be compared, ranged or partitioned by day without a cast.",
            &[],
        ),
        check(
            "types.drift",
            "A column name has one type everywhere",
            Should,
            "The same name with two types breaks joins and misleads whoever reads it.",
            &[],
        ),
        check(
            "types.money",
            "Money is decimal, never float or double",
            Must,
            "Floating point cannot hold cents exactly.",
            &[],
        ),
        pack(
            "pk",
            "Primary key",
            "Every table can name the one row it holds.",
            &["pk.present", "pk.required", "pk.ident"],
        ),
        check("pk.present", "Every table has a key", Must, "Without a key, no change can be applied to one row.", &[]),
        check("pk.required", "Key columns are required", Must, "A key that may be empty identifies nothing.", &[]),
        check(
            "pk.ident",
            "The key is declared as Iceberg identifier fields",
            Must,
            "Upserts, merge-on-read deletes and CDC find rows by the identifier fields.",
            ICEBERG,
        ),
        pack(
            "naming",
            "Naming: snake_case",
            "Names you can guess: lower case, words joined by underscores.",
            &["naming.case"],
        ),
        check(
            "naming.case",
            "Names are snake_case",
            Should,
            "Mixed case must be quoted in some databases and guessed in all of them.",
            &[],
        ),
        pack("docs", "Descriptions", "Everything says what it is.", &["docs.table", "docs.column"]),
        check(
            "docs.table",
            "Every table has a description",
            Should,
            "The agent and the next person read it before they read the columns.",
            &[],
        ),
        check(
            "docs.column",
            "Every column has a description",
            Should,
            "A name alone rarely says the unit, the source or what empty means.",
            &[],
        ),
        pack(
            "norm",
            "Normalization",
            "Each fact stored once: for operational schemas.",
            &["norm.repeat", "norm.copies", "norm.lists"],
        ),
        check(
            "norm.repeat",
            "No repeating groups (phone1, phone2, phone3)",
            Should,
            "A fixed number of slots: the next one needs a new column.",
            &[],
        ),
        check(
            "norm.copies",
            "No attribute copied from a table it refers to",
            Should,
            "A copy goes stale when its source changes.",
            &[],
        ),
        check("norm.lists", "No list kept in a string", Should, "A list in a string cannot be joined or checked.", &[]),
        pack("denorm", "Denormalization", "Facts carry what they are read with: for analytics.", &["denorm.source"]),
        check(
            "denorm.source",
            "A copied attribute names its source",
            Must,
            "Its description names the table it is copied from, so it can be refreshed.",
            &[],
        ),
        pack(
            "scd2",
            "SCD Type 2 history",
            "Every change is a new row, so any past state can be read back.",
            &["scd2.columns"],
        ),
        check(
            "scd2.columns",
            "Rows carry valid_from and valid_to",
            Must,
            "They say when each version of a row held.",
            &[],
        ),
        pack("audit", "Audit columns", "Every row says when it was made and last changed.", &["audit.columns"]),
        check(
            "audit.columns",
            "Rows carry created_at and updated_at",
            Should,
            "When a row was made and last changed.",
            &[],
        ),
        pack("mor", "Iceberg merge-on-read", "Fast writes for tables that change often.", &["mor.modes"]),
        check(
            "mor.modes",
            "Deletes, updates and merges are merge-on-read",
            Should,
            "Each change writes a small delete file instead of rewriting data files.",
            ICEBERG,
        ),
        pack(
            "cdc",
            "CDC-ready: Debezium → Iceberg",
            "Changes stream from MySQL or PostgreSQL through Debezium and land once, in order, on the right row.",
            &["pk", "types.time", "mor.modes", "cdc.position", "cdc.source"],
        ),
        check(
            "cdc.position",
            "Each row keeps the change's position and time",
            Should,
            "Late and repeated changes are put in order and duplicates dropped by the source position (LSN, binlog) and time.",
            ICEBERG,
        ),
        check(
            "cdc.source",
            "Types Debezium carries well",
            Should,
            "Some source types arrive changed, approximated or as placeholders.",
            SOURCES,
        ),
        pack("mysql", "MySQL basics", "What every MySQL table should be.", &["mysql.engine", "mysql.charset"]),
        check(
            "mysql.engine",
            "Tables use InnoDB",
            Must,
            "Transactions, row locks and crash recovery; other engines have none of them.",
            MYSQL,
        ),
        check(
            "mysql.charset",
            "Text is utf8mb4",
            Should,
            "utf8 (utf8mb3) cannot hold all of Unicode: emoji and some scripts are cut.",
            MYSQL,
        ),
        pack(
            "postgres",
            "PostgreSQL basics",
            "What every PostgreSQL table should be.",
            &["pg.timestamptz", "pg.identity"],
        ),
        check(
            "pg.timestamptz",
            "Times are timestamptz",
            Should,
            "A timestamp without a zone is read in whatever zone the session has.",
            POSTGRES,
        ),
        check(
            "pg.identity",
            "Keys are identity columns, not serial",
            Should,
            "Identity columns are the SQL standard and own their sequence; serial does not.",
            POSTGRES,
        ),
        pack(
            "iceberg",
            "Iceberg basics",
            "What every Iceberg table should be.",
            &["iceberg.format", "mor", "pk.ident"],
        ),
        check(
            "iceberg.format",
            "The format version is set to 2 or 3",
            Should,
            "Row-level deletes need format 2; nanosecond times and variant need 3.",
            ICEBERG,
        ),
    ];
    for m in MAPS {
        let id = format!("compat.{}", m.id);
        let title = format!("{} → {}", target_title(m.from), target_title(m.to));
        let mut p = pack(&id, &title, "", &[]);
        p.why = format!("This {} schema could also be built in {}.", target_title(m.from), target_title(m.to));
        p.rules = vec![format!("{id}.lossy"), format!("{id}.decide")];
        rules.push(p);
        rules.push(check(
            &format!("{id}.lossy"),
            &format!("Nothing is lost in {}", target_title(m.to)),
            Must,
            "A type that loses part of its value, or has no type, on the other side.",
            &[m.from],
        ));
        rules.push(check(
            &format!("{id}.decide"),
            &format!("Every choice for {} is made", target_title(m.to)),
            Should,
            "A type with more than one fitting type on the other side.",
            &[m.from],
        ));
    }
    for r in &mut rules {
        classify(r);
    }
    Catalog { rules, goals: goals(), maps: MAPS }
}

/// Sorts a rule into its lane and topic.
fn classify(r: &mut Rule) {
    match r.id.as_str() {
        "mor" | "iceberg" => r.targets = ICEBERG.to_vec(),
        "mysql" => r.targets = MYSQL.to_vec(),
        "postgres" => r.targets = POSTGRES.to_vec(),
        _ => {}
    }
    let head = r.id.split('.').next().unwrap_or("");
    r.topic = match (head, r.id.as_str()) {
        (_, "mysql.charset" | "pg.timestamptz") => "types",
        (_, "pg.identity") => "keys",
        (_, "mysql.engine" | "iceberg.format") => "storage",
        ("types", _) => "types",
        ("pk", _) => "keys",
        ("naming", _) => "naming",
        ("docs", _) => "documentation",
        ("norm" | "denorm", _) => "normalization",
        ("scd2" | "audit", _) => "history",
        ("mor" | "iceberg", _) => "storage",
        ("cdc", _) => "cdc",
        ("compat", _) => "compatibility",
        _ => "basics",
    };
    r.lane = if r.topic == "compatibility" || r.id == "cdc" || r.targets.len() > 1 {
        Lane::Between
    } else {
        match r.targets.first() {
            None => Lane::Shared,
            Some(Target::Mysql) => Lane::Mysql,
            Some(Target::Postgres) => Lane::Postgres,
            Some(Target::Iceberg) => Lane::Iceberg,
        }
    };
}

fn goals() -> Vec<Goal> {
    let mysql_side = vec![
        ("binlog_format = ROW", "every changed row, not the statement"),
        ("binlog_row_image = FULL", "the whole row before and after"),
        ("gtid_mode = ON", "recommended: the connector can resume on another server"),
        (
            "a user with REPLICATION SLAVE, REPLICATION CLIENT, SELECT, RELOAD",
            "to read the binlog and take the first snapshot",
        ),
        ("binlog kept long enough", "longer than any pause of the connector"),
    ];
    let postgres_side = vec![
        ("wal_level = logical", "the log carries row changes"),
        ("a publication and a replication slot (pgoutput)", "what to stream, and where the connector left off"),
        ("max_replication_slots, max_wal_senders", "room for the connector"),
        (
            "a user with REPLICATION and SELECT",
            "to stream and to snapshot; creating the publication needs ownership of the tables",
        ),
        ("REPLICA IDENTITY FULL on tables without a key", "or their updates and deletes carry no old key"),
    ];
    vec![
        Goal {
            id: "cdc",
            title: "Feed it by CDC",
            about: "Changes stream from MySQL or PostgreSQL through Debezium into Iceberg.",
            packs: vec![(Target::Iceberg, vec!["cdc"]), (Target::Mysql, vec!["cdc"]), (Target::Postgres, vec!["cdc"])],
            outside: vec![(Target::Mysql, mysql_side), (Target::Postgres, postgres_side)],
        },
        Goal {
            id: "mysql-postgres",
            title: "Build in MySQL and PostgreSQL",
            about: "One schema the same application runs on, in either database.",
            packs: vec![
                (Target::Mysql, vec!["compat.mysql-postgres", "naming", "pk"]),
                (Target::Postgres, vec!["compat.postgres-mysql", "naming", "pk"]),
            ],
            outside: Vec::new(),
        },
        Goal {
            id: "postgres-iceberg",
            title: "Move PostgreSQL to Iceberg",
            about: "A PostgreSQL schema whose tables also land in Iceberg, by CDC or by copy.",
            packs: vec![(Target::Postgres, vec!["compat.postgres-iceberg", "pk"])],
            outside: Vec::new(),
        },
        Goal {
            id: "mysql-iceberg",
            title: "Move MySQL to Iceberg",
            about: "A MySQL schema whose tables also land in Iceberg.",
            packs: vec![(Target::Mysql, vec!["compat.mysql-iceberg", "pk"])],
            outside: Vec::new(),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_rule_a_pack_names_exists_and_ids_are_unique() {
        let c = catalog();
        let mut ids: Vec<&str> = c.rules.iter().map(|r| r.id.as_str()).collect();
        ids.sort_unstable();
        let n = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), n, "ids are unique");
        for r in &c.rules {
            for child in &r.rules {
                assert!(c.rule(child).is_some(), "{} names {child}", r.id);
            }
        }
        for g in &c.goals {
            for (_, packs) in &g.packs {
                for p in packs {
                    assert!(c.rule(p).is_some(), "goal {} names {p}", g.id);
                }
            }
        }
    }

    #[test]
    fn every_rule_has_a_lane_and_a_topic() {
        let c = catalog();
        for r in &c.rules {
            assert!(!r.topic.is_empty() && r.topic != "basics" || !r.rules.is_empty(), "{} has a topic", r.id);
        }
        let lane = |id: &str| c.rule(id).map(|r| r.lane);
        assert_eq!(lane("pk.present"), Some(Lane::Shared), "nothing without a key, everywhere");
        assert_eq!(lane("pk.ident"), Some(Lane::Iceberg));
        assert_eq!(lane("mysql.engine"), Some(Lane::Mysql));
        assert_eq!(lane("pg.identity"), Some(Lane::Postgres));
        assert_eq!(lane("compat.mysql-postgres"), Some(Lane::Between));
        assert_eq!(lane("cdc"), Some(Lane::Between));
    }

    #[test]
    fn a_pack_inside_a_pack_brings_its_checks() {
        let c = catalog();
        let checks = c.checks("cdc");
        assert!(checks.contains(&"pk.ident"), "cdc holds the pk pack");
        assert!(checks.contains(&"types.time"));
        assert!(c.contains("cdc", "pk.required"));
        assert!(!c.contains("pk", "cdc"));
    }
}
