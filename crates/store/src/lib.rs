//! The embedded store (docs/store.md): one redb file of text keys to JSON values. The current model is kept
//! as one record per top-level object beside an append-only log of operations; every committed change is
//! announced to subscribers.

use std::path::Path;

use redb::{Database, ReadableDatabase, ReadableTable, TableDefinition};
use schema_forge_core::ops::{self, Op};
use schema_forge_core::rules::custom::CustomRule;
use schema_forge_core::rules::review::{self, Proposal, Proposed, Status};
use schema_forge_core::rules::{self, Catalog, Enforce, Finding, Group, Link, RuleSet, Scope};
use schema_forge_core::{Id, Schema, Target};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::broadcast;

/// The format of the store file this crate reads and writes.
pub const FORMAT: u64 = 1;

const META: TableDefinition<&str, u64> = TableDefinition::new("meta");
const SCHEMAS: TableDefinition<&str, &str> = TableDefinition::new("schemas");
const OBJECTS: TableDefinition<&str, &str> = TableDefinition::new("objects");
const OPERATIONS: TableDefinition<&str, &str> = TableDefinition::new("operations");
/// A schema's links and groups by its name; the workspace's global links under [`GLOBAL`].
const RULES: TableDefinition<&str, &str> = TableDefinition::new("rules");
/// The workspace's own rules, written by the agent and approved, by id (`custom.<n>`).
const CUSTOM: TableDefinition<&str, &str> = TableDefinition::new("custom_rules");
/// The agent's turns, by `<schema>/<n>`: the changes it made for one prompt, accepted or rejected together.
const TURNS: TableDefinition<&str, &str> = TableDefinition::new("turns");
/// Rules the agent proposed, by `<schema>/<n>`.
const PROPOSALS: TableDefinition<&str, &str> = TableDefinition::new("proposals");

/// The key of the global links, and the log they are recorded in: not a schema name, so never one's.
pub const GLOBAL: &str = "*";

/// What can go wrong with the store.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("the store: {0}")]
    Db(String),
    #[error("a stored record is not valid: {0}")]
    Record(#[from] serde_json::Error),
    #[error("the store's format is {found}; this schema-forge reads format {FORMAT}")]
    Format { found: u64 },
    #[error("there is no schema `{0}`")]
    NoSchema(String),
    #[error("a schema `{0}` already exists")]
    SchemaExists(String),
    #[error("`{0}` is not a schema name: use lowercase letters, digits, `-` and `_`, starting with a letter")]
    BadName(String),
    #[error("{0}")]
    Rule(String),
    /// A change refused: by the model's rules, a hard rule, or for want of a yes.
    #[error("{0}")]
    Refused(String),
    #[error("schema `{name}` is {schema:?}; the model given is {model:?}")]
    WrongTarget { name: String, schema: Target, model: Target },
}

macro_rules! db_errors {
    ($($t:ty),* $(,)?) => {
        $(impl From<$t> for Error {
            fn from(e: $t) -> Self {
                Self::Db(e.to_string())
            }
        })*
    };
}
db_errors!(
    redb::Error,
    redb::DatabaseError,
    redb::TransactionError,
    redb::TableError,
    redb::StorageError,
    redb::CommitError
);

pub type Result<T> = std::result::Result<T, Error>;

/// A schema's own record: its name, its type, the model's format.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchemaInfo {
    pub name: String,
    pub target: Target,
    pub format: u32,
}

/// One change, as appended to the log.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Operation {
    /// Its place in the schema's log, from 1.
    pub sequence: u64,
    /// `import`, `add_table`, …
    pub kind: String,
    /// `agent`, `import`, `file`.
    pub by: String,
    /// The change, as the kind defines it.
    pub change: Value,
}

/// A change made: its place in the log, what each operation did, and the soft rules it now breaks (highlighted, not
/// refused).
#[derive(Debug, Clone, PartialEq)]
pub struct Changed {
    pub operation: Operation,
    pub summaries: Vec<String>,
    pub soft: Vec<Finding>,
}

/// One turn of the agent: what it was asked, as it says it, and the changes it made for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Turn {
    pub id: u64,
    pub by: String,
    pub summary: String,
    pub status: TurnStatus,
    /// The changes made in it, by their place in the log.
    pub changes: Vec<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decided_by: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TurnStatus {
    Open,
    Accepted,
    Rejected,
}

/// What subscribers hear after each commit.
#[derive(Debug, Clone, PartialEq)]
pub struct Change {
    pub schema: String,
    pub operation: Operation,
}

/// The store.
pub struct Store {
    db: Database,
    changes: broadcast::Sender<Change>,
}

/// One top-level object of the model, as stored: its section, its place there, and the object itself.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Record {
    section: Section,
    position: usize,
    object: Value,
}

/// The model's sections, in the order a schema lists them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Section {
    Namespaces,
    Areas,
    Tables,
    Relationships,
    Views,
    Sequences,
    Types,
    Kept,
}

const SECTIONS: [Section; 8] = [
    Section::Namespaces,
    Section::Areas,
    Section::Tables,
    Section::Relationships,
    Section::Views,
    Section::Sequences,
    Section::Types,
    Section::Kept,
];

impl Section {
    const fn key(self) -> &'static str {
        match self {
            Self::Namespaces => "namespaces",
            Self::Areas => "areas",
            Self::Tables => "tables",
            Self::Relationships => "relationships",
            Self::Views => "views",
            Self::Sequences => "sequences",
            Self::Types => "types",
            Self::Kept => "kept",
        }
    }
}

impl Store {
    /// Opens the store at `path`, creating it if there is none.
    ///
    /// # Errors
    /// When the file cannot be opened, or holds a format this version does not read.
    pub fn open(path: &Path) -> Result<Self> {
        let db = Database::create(path)?;
        let txn = db.begin_write()?;
        {
            let mut meta = txn.open_table(META)?;
            let found = meta.get("format")?.map(|v| v.value());
            match found {
                None => {
                    meta.insert("format", FORMAT)?;
                }
                Some(f) if f == FORMAT => {}
                Some(found) => return Err(Error::Format { found }),
            }
            txn.open_table(SCHEMAS)?;
            txn.open_table(OBJECTS)?;
            txn.open_table(OPERATIONS)?;
            txn.open_table(RULES)?;
            txn.open_table(CUSTOM)?;
            txn.open_table(PROPOSALS)?;
            txn.open_table(TURNS)?;
        }
        txn.commit()?;
        let (changes, _) = broadcast::channel(1024);
        Ok(Self { db, changes })
    }

    /// Hear every change committed from now on.
    #[must_use]
    pub fn subscribe(&self) -> broadcast::Receiver<Change> {
        self.changes.subscribe()
    }

    /// Makes an empty schema called `name`.
    ///
    /// # Errors
    /// When the name is taken or not a valid name, or the store fails.
    pub fn create_schema(&self, name: &str, target: Target) -> Result<SchemaInfo> {
        valid_name(name)?;
        let info = SchemaInfo { name: name.to_string(), target, format: schema_forge_core::FORMAT };
        let txn = self.db.begin_write()?;
        {
            let mut schemas = txn.open_table(SCHEMAS)?;
            if schemas.get(name)?.is_some() {
                return Err(Error::SchemaExists(name.to_string()));
            }
            schemas.insert(name, serde_json::to_string(&info)?.as_str())?;
        }
        txn.commit()?;
        Ok(info)
    }

    /// Every schema, by name.
    ///
    /// # Errors
    /// When the store fails or a record is not valid.
    pub fn schemas(&self) -> Result<Vec<SchemaInfo>> {
        let txn = self.db.begin_read()?;
        let schemas = txn.open_table(SCHEMAS)?;
        let mut out = Vec::new();
        for entry in schemas.iter()? {
            let (_, v) = entry?;
            out.push(serde_json::from_str(v.value())?);
        }
        Ok(out)
    }

    /// The schema's current model, read back from its records.
    ///
    /// # Errors
    /// When there is no such schema, the store fails or a record is not valid.
    pub fn model(&self, name: &str) -> Result<Schema> {
        let txn = self.db.begin_read()?;
        let info = schema_info(&txn.open_table(SCHEMAS)?, name)?;
        let objects = txn.open_table(OBJECTS)?;
        let (lo, hi) = prefix_range(name);
        let mut records: Vec<Record> = Vec::new();
        for entry in objects.range(lo.as_str()..hi.as_str())? {
            let (_, v) = entry?;
            records.push(serde_json::from_str(v.value())?);
        }
        records.sort_by_key(|r| (r.section, r.position));
        let mut doc = serde_json::Map::new();
        doc.insert("format".to_string(), Value::from(info.format));
        doc.insert("target".to_string(), serde_json::to_value(info.target)?);
        for section in SECTIONS {
            let items: Vec<Value> = records.iter().filter(|r| r.section == section).map(|r| r.object.clone()).collect();
            if !items.is_empty() {
                doc.insert(section.key().to_string(), Value::Array(items));
            }
        }
        Ok(serde_json::from_value(Value::Object(doc))?)
    }

    /// Replaces the schema's whole model with `model` in one transaction, logs it as one operation of `kind`
    /// by `by`, and announces it. Used by import; the agent's changes touch only the records they change.
    ///
    /// # Errors
    /// When there is no such schema, the model's target differs from the schema's, or the store fails.
    pub fn replace_model(&self, name: &str, model: &Schema, kind: &str, by: &str) -> Result<Operation> {
        let txn = self.db.begin_write()?;
        let operation;
        {
            let info = schema_info(&txn.open_table(SCHEMAS)?, name)?;
            if info.target != model.target {
                return Err(Error::WrongTarget { name: name.to_string(), schema: info.target, model: model.target });
            }
            let mut objects = txn.open_table(OBJECTS)?;
            let (lo, hi) = prefix_range(name);
            let old: Vec<String> = objects
                .range(lo.as_str()..hi.as_str())?
                .map(|e| e.map(|(k, _)| k.value().to_string()))
                .collect::<std::result::Result<_, _>>()?;
            for key in old {
                objects.remove(key.as_str())?;
            }
            for (id, record) in records(model)? {
                objects.insert(format!("{name}/{id}").as_str(), serde_json::to_string(&record)?.as_str())?;
            }
            let mut ops = txn.open_table(OPERATIONS)?;
            let sequence = last_sequence(&ops, name)? + 1;
            operation = Operation {
                sequence,
                kind: kind.to_string(),
                by: by.to_string(),
                change: serde_json::json!({ "hash": schema_forge_core::hash(model) }),
            };
            ops.insert(operation_key(name, sequence).as_str(), serde_json::to_string(&operation)?.as_str())?;
        }
        txn.commit()?;
        // Nobody listening is fine: the change is stored.
        let _ = self.changes.send(Change { schema: name.to_string(), operation: operation.clone() });
        Ok(operation)
    }

    /// The schema's log, oldest first.
    ///
    /// # Errors
    /// When the store fails or a record is not valid.
    pub fn operations(&self, name: &str) -> Result<Vec<Operation>> {
        let txn = self.db.begin_read()?;
        let ops = txn.open_table(OPERATIONS)?;
        let (lo, hi) = prefix_range(name);
        let mut out = Vec::new();
        for entry in ops.range(lo.as_str()..hi.as_str())? {
            let (_, v) = entry?;
            out.push(serde_json::from_str(v.value())?);
        }
        Ok(out)
    }
}

/// Where a rule change goes: one schema's rules, or every schema's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rules<'a> {
    Global,
    Schema(&'a str),
}

impl Rules<'_> {
    fn key(self) -> String {
        match self {
            Self::Global => GLOBAL.to_string(),
            Self::Schema(name) => name.to_string(),
        }
    }
}

impl Store {
    /// The schema's links and groups.
    ///
    /// # Errors
    /// When there is no such schema, the store fails or a record is not valid.
    pub fn rules(&self, name: &str) -> Result<RuleSet> {
        let txn = self.db.begin_read()?;
        schema_info(&txn.open_table(SCHEMAS)?, name)?;
        read_rules(&txn.open_table(RULES)?, name)
    }

    /// The links every schema of the workspace has.
    ///
    /// # Errors
    /// When the store fails or the record is not valid.
    pub fn global_rules(&self) -> Result<Vec<Link>> {
        let txn = self.db.begin_read()?;
        Ok(read_rules(&txn.open_table(RULES)?, GLOBAL)?.links)
    }

    /// Links a rule, or an exception, after checking it holds: against this schema, or for global links against
    /// every schema of the workspace.
    ///
    /// # Errors
    /// When the link does not hold ([`Error::Rule`]), there is no such schema, or the store fails.
    pub fn link_rule(&self, to: Rules<'_>, link: Link, by: &str) -> Result<Operation> {
        let global = self.global_rules()?;
        match to {
            Rules::Schema(name) => {
                if link.at == Scope::Global {
                    return Err(Error::Rule("a global link goes to every schema, not one".to_string()));
                }
                rules::admit(&self.catalog()?, &self.model(name)?, &global, &self.rules(name)?, &link)
                    .map_err(Error::Rule)?;
            }
            Rules::Global => {
                if link.at != Scope::Global {
                    return Err(Error::Rule("a link for every schema is at the global level".to_string()));
                }
                let cat = self.catalog()?;
                for info in self.schemas()? {
                    let set = self.rules(&info.name)?;
                    rules::admit(&cat, &self.model(&info.name)?, &global, &set, &link)
                        .map_err(|e| Error::Rule(format!("{}: {e}", info.name)))?;
                }
                if cat.rule(&link.rule).is_none() {
                    return Err(Error::Rule(format!("there is no rule `{}`", link.rule)));
                }
            }
        }
        let change = serde_json::to_value(&link)?;
        self.change_rules(to, "link_rule", by, change, |set| {
            set.links.push(link);
            Ok(())
        })
    }

    /// Takes away the link or exception of `rule` at `at`.
    ///
    /// # Errors
    /// When there is none, there is no such schema, or the store fails.
    pub fn unlink_rule(&self, to: Rules<'_>, rule: &str, at: &Scope, by: &str) -> Result<Operation> {
        let change = serde_json::json!({ "rule": rule, "at": at });
        self.change_rules(to, "unlink_rule", by, change, |set| {
            let before = set.links.len();
            set.links.retain(|l| !(l.rule == rule && &l.at == at));
            if set.links.len() == before {
                return Err(Error::Rule(format!("`{rule}` is not linked at {}", rules::describe(at))));
            }
            Ok(())
        })
    }

    /// Makes or replaces a group of tables.
    ///
    /// # Errors
    /// When a table is not in the schema, there is no such schema, or the store fails.
    pub fn set_group(&self, name: &str, group: Group, by: &str) -> Result<Operation> {
        let model = self.model(name)?;
        if group.name.trim().is_empty() {
            return Err(Error::Rule("a group needs a name".to_string()));
        }
        if let Some(t) = group.tables.iter().find(|t| !model.tables.iter().any(|m| &m.id == *t)) {
            return Err(Error::Rule(format!("there is no table `{t}` in `{name}`")));
        }
        let change = serde_json::to_value(&group)?;
        self.change_rules(Rules::Schema(name), "set_group", by, change, |set| {
            set.groups.retain(|g| g.name != group.name);
            set.groups.push(group);
            Ok(())
        })
    }

    /// Takes away a group no rule is linked to.
    ///
    /// # Errors
    /// When rules are linked to it, there is no such group or schema, or the store fails.
    pub fn remove_group(&self, name: &str, group: &str, by: &str) -> Result<Operation> {
        let change = serde_json::json!({ "group": group });
        self.change_rules(Rules::Schema(name), "remove_group", by, change, |set| {
            let at = Scope::Group { group: group.to_string() };
            if set.links.iter().any(|l| l.at == at) {
                return Err(Error::Rule(format!("rules are linked to group `{group}`: take them away first")));
            }
            let before = set.groups.len();
            set.groups.retain(|g| g.name != group);
            if set.groups.len() == before {
                return Err(Error::Rule(format!("there is no group `{group}`")));
            }
            Ok(())
        })
    }

    /// Sets how a link holds: hard (enforced) or soft (highlighted only).
    ///
    /// # Errors
    /// When nothing is linked there, there is no such schema, or the store fails.
    pub fn set_enforce(&self, to: Rules<'_>, rule: &str, at: &Scope, enforce: Enforce, by: &str) -> Result<Operation> {
        let change = serde_json::json!({ "rule": rule, "at": at, "enforce": enforce });
        self.change_rules(to, "enforce_rule", by, change, |set| {
            let link = set.links.iter_mut().find(|l| l.rule == rule && &l.at == at && !l.off);
            match link {
                Some(l) => {
                    l.enforce = Some(enforce);
                    Ok(())
                }
                None => Err(Error::Rule(format!("`{rule}` is not linked at {}", rules::describe(at)))),
            }
        })
    }

    /// The workspace's own rules.
    ///
    /// # Errors
    /// When the store fails or a record is not valid.
    pub fn custom_rules(&self) -> Result<Vec<CustomRule>> {
        let txn = self.db.begin_read()?;
        let table = txn.open_table(CUSTOM)?;
        let mut out = Vec::new();
        for entry in table.iter()? {
            let (_, v) = entry?;
            out.push(serde_json::from_str(v.value())?);
        }
        Ok(out)
    }

    /// The built-in rules and the workspace's own.
    ///
    /// # Errors
    /// When the store fails or a record is not valid.
    pub fn catalog(&self) -> Result<Catalog> {
        Ok(rules::catalog().with(&self.custom_rules()?))
    }

    /// The schema's proposals, oldest first.
    ///
    /// # Errors
    /// When there is no such schema, the store fails or a record is not valid.
    pub fn proposals(&self, name: &str) -> Result<Vec<Proposal>> {
        let txn = self.db.begin_read()?;
        schema_info(&txn.open_table(SCHEMAS)?, name)?;
        let table = txn.open_table(PROPOSALS)?;
        let (lo, hi) = prefix_range(name);
        let mut out = Vec::new();
        for entry in table.range(lo.as_str()..hi.as_str())? {
            let (_, v) = entry?;
            out.push(serde_json::from_str(v.value())?);
        }
        Ok(out)
    }

    /// Keeps the agent's proposals for review, numbered from the schema's last.
    ///
    /// # Errors
    /// When there is no such schema, or the store fails.
    pub fn propose(
        &self,
        name: &str,
        items: Vec<(Proposed, Scope, Enforce, String)>,
        by: &str,
    ) -> Result<Vec<Proposal>> {
        let txn = self.db.begin_write()?;
        let mut kept = Vec::new();
        let operation;
        {
            schema_info(&txn.open_table(SCHEMAS)?, name)?;
            let mut table = txn.open_table(PROPOSALS)?;
            let (lo, hi) = prefix_range(name);
            let last = match table.range(lo.as_str()..hi.as_str())?.next_back().transpose()? {
                Some((_, v)) => serde_json::from_str::<Proposal>(v.value())?.id,
                None => 0,
            };
            for (i, (what, at, enforce, why)) in items.into_iter().enumerate() {
                let p = Proposal {
                    id: last + 1 + i as u64,
                    by: by.to_string(),
                    what,
                    at,
                    enforce,
                    why,
                    status: Status::Proposed,
                    decided_by: None,
                    rule: None,
                };
                table.insert(proposal_key(name, p.id).as_str(), serde_json::to_string(&p)?.as_str())?;
                kept.push(p);
            }
            let mut ops = txn.open_table(OPERATIONS)?;
            let sequence = last_sequence(&ops, name)? + 1;
            let ids: Vec<u64> = kept.iter().map(|p| p.id).collect();
            operation = Operation {
                sequence,
                kind: "propose_rules".to_string(),
                by: by.to_string(),
                change: serde_json::json!({ "proposals": ids }),
            };
            ops.insert(operation_key(name, sequence).as_str(), serde_json::to_string(&operation)?.as_str())?;
        }
        txn.commit()?;
        let _ = self.changes.send(Change { schema: name.to_string(), operation });
        Ok(kept)
    }

    /// Changes a proposal before it is decided: whether it would hold hard or soft.
    ///
    /// # Errors
    /// When there is no such proposal, it is decided, or the store fails.
    pub fn set_proposal_enforce(&self, name: &str, id: u64, enforce: Enforce, by: &str) -> Result<Proposal> {
        self.change_proposal(name, id, "change_proposal", by, |p| {
            p.enforce = enforce;
            Ok(None)
        })
    }

    /// Approves or rejects a proposal. Approving verifies it again: an invalid or duplicate one is refused; a new
    /// rule is kept in the workspace and linked, a link or an exception is added, all in one transaction.
    ///
    /// # Errors
    /// When it does not verify, is already decided, there is no such proposal or schema, or the store fails.
    pub fn decide(&self, name: &str, id: u64, approve: bool, by: &str) -> Result<Proposal> {
        let kind = if approve { "approve_rule" } else { "reject_rule" };
        if !approve {
            return self.change_proposal(name, id, kind, by, |p| {
                p.status = Status::Rejected;
                p.decided_by = Some(by.to_string());
                Ok(None)
            });
        }
        let model = self.model(name)?;
        let global = self.global_rules()?;
        let set = self.rules(name)?;
        let custom = self.custom_rules()?;
        let cat = rules::catalog().with(&custom);
        let all = self.proposals(name)?;
        let p = all.iter().find(|p| p.id == id).ok_or_else(|| Error::Rule(format!("there is no proposal #{id}")))?;
        let verdict = review::verify(
            &review::Context {
                cat: &cat,
                custom: &custom,
                schema: &model,
                global: &global,
                set: &set,
                proposals: &all,
            },
            p,
        );
        match verdict.state {
            review::State::Invalid => {
                return Err(Error::Rule(format!(
                    "proposal #{id} does not verify: {}",
                    verdict.notes.iter().map(|n| n.text.as_str()).collect::<Vec<_>>().join("; ")
                )));
            }
            review::State::Duplicate => {
                return Err(Error::Rule(format!("proposal #{id} repeats a rule or a proposal: reject it")));
            }
            review::State::Ready | review::State::Conflict => {}
        }
        let new_id = format!("custom.{}", custom.len() + 1);
        let rule = match &p.what {
            Proposed::New { .. } => new_id.clone(),
            Proposed::Link { rule } | Proposed::Off { rule, .. } => rule.clone(),
        };
        let draft = review::draft(p, &new_id, by, name);
        let link = review::link_of(p, &rule);
        self.change_proposal(name, id, kind, by, move |p| {
            p.status = Status::Approved;
            p.decided_by = Some(by.to_string());
            p.rule = Some(rule);
            Ok(Some((draft, link)))
        })
    }

    /// Reads proposal `id`, applies `edit`, and keeps what the edit hands back (a new rule, a link), in one
    /// transaction with the log.
    #[allow(clippy::type_complexity)]
    fn change_proposal(
        &self,
        name: &str,
        id: u64,
        kind: &str,
        by: &str,
        edit: impl FnOnce(&mut Proposal) -> Result<Option<(Option<CustomRule>, Link)>>,
    ) -> Result<Proposal> {
        let txn = self.db.begin_write()?;
        let proposal;
        let operation;
        {
            schema_info(&txn.open_table(SCHEMAS)?, name)?;
            let mut table = txn.open_table(PROPOSALS)?;
            let key = proposal_key(name, id);
            let mut p: Proposal = match table.get(key.as_str())? {
                Some(v) => serde_json::from_str(v.value())?,
                None => return Err(Error::Rule(format!("there is no proposal #{id}"))),
            };
            if p.status != Status::Proposed {
                return Err(Error::Rule(format!("proposal #{id} is already {:?}", p.status).to_lowercase()));
            }
            if let Some((rule, link)) = edit(&mut p)? {
                if let Some(rule) = rule {
                    txn.open_table(CUSTOM)?.insert(rule.id.as_str(), serde_json::to_string(&rule)?.as_str())?;
                }
                let mut rules_table = txn.open_table(RULES)?;
                let mut set = read_rules(&rules_table, name)?;
                set.links.retain(|l| !(l.rule == link.rule && l.at == link.at));
                set.links.push(link);
                rules_table.insert(name, serde_json::to_string(&set)?.as_str())?;
            }
            table.insert(key.as_str(), serde_json::to_string(&p)?.as_str())?;
            let mut ops = txn.open_table(OPERATIONS)?;
            let sequence = last_sequence(&ops, name)? + 1;
            operation = Operation {
                sequence,
                kind: kind.to_string(),
                by: by.to_string(),
                change: serde_json::json!({ "proposal": id }),
            };
            ops.insert(operation_key(name, sequence).as_str(), serde_json::to_string(&operation)?.as_str())?;
            proposal = p;
        }
        txn.commit()?;
        let _ = self.changes.send(Change { schema: name.to_string(), operation });
        Ok(proposal)
    }

    /// Applies `ops` to the schema as one change, all or nothing: each is checked against the model's own rules as it
    /// applies; then the whole is checked against the schema's rules, and refused if it breaks a hard rule that held
    /// before. The records it touches are written with what they were, so the change can be undone.
    ///
    /// # Errors
    /// [`Error::Refused`] with the operation and the reason, or when there is no such schema or the store fails.
    /// Hard rules hold for everyone, the agent and you alike: to go ahead, a rule is turned soft first.
    pub fn change(&self, name: &str, ops: &[Op], confirmed: bool, by: &str) -> Result<Changed> {
        self.change_in(name, ops, confirmed, by, None)
    }

    /// As [`Store::change`], kept in turn `turn` when one is given.
    ///
    /// # Errors
    /// As [`Store::change`], and when the turn is not open.
    pub fn change_in(&self, name: &str, ops: &[Op], confirmed: bool, by: &str, turn: Option<u64>) -> Result<Changed> {
        if let Some(n) = turn {
            let t = self
                .turns(name)?
                .into_iter()
                .find(|t| t.id == n)
                .ok_or_else(|| Error::Refused(format!("there is no turn {n}")))?;
            if t.status != TurnStatus::Open {
                return Err(Error::Refused(format!("turn {n} is {:?}: start a new one", t.status).to_lowercase()));
            }
        }
        if ops.is_empty() {
            return Err(Error::Refused("no operations".to_string()));
        }
        let old = self.model(name)?;
        let cat = self.catalog()?;
        let global = self.global_rules()?;
        let set = self.rules(name)?;
        let mut model = old.clone();
        let mut summaries = Vec::new();
        for (i, op) in ops.iter().enumerate() {
            let done = ops::apply(&mut model, op, confirmed)
                .map_err(|e| Error::Refused(format!("operation {}: {e}", i + 1)))?;
            summaries.push(done.summary);
        }
        let key = |f: &Finding| (f.rule.clone(), f.table.clone(), f.column.clone(), f.message.clone());
        let before: std::collections::HashSet<_> =
            rules::check_with(&cat, &old, &global, &set).findings.iter().map(key).collect();
        let after = rules::check_with(&cat, &model, &global, &set);
        let new: Vec<&Finding> = after.findings.iter().filter(|f| !before.contains(&key(f))).collect();
        // Hard means hard: a table the change touches keeps every hard rule on it, breaks it had before included;
        // and nothing anywhere may newly break one.
        let touched: std::collections::HashSet<&Id> = model
            .tables
            .iter()
            .filter(|t| old.tables.iter().find(|o| o.id == t.id) != Some(*t))
            .map(|t| &t.id)
            .collect();
        let refusing: Vec<&Finding> = after
            .findings
            .iter()
            .filter(|f| f.hard && (touched.contains(&f.table) || !before.contains(&key(f))))
            .collect();
        let hard: Vec<String> = refusing
            .iter()
            .take(10)
            .map(|f| {
                let title = cat.rule(&f.rule).map_or(f.rule.as_str(), |r| r.title.as_str());
                let table = model.tables.iter().find(|t| t.id == f.table).map_or(f.table.as_str(), |t| t.name.as_str());
                format!("\"{title}\" (@rule:{}) on `{table}`: {}", f.rule, f.message)
            })
            .collect();
        if !hard.is_empty() {
            let more = refusing.len().saturating_sub(hard.len());
            return Err(Error::Refused(format!(
                "refused: hard rules would be broken: {}{}",
                hard.join("; "),
                if more > 0 { format!("; and {more} more") } else { String::new() }
            )));
        }
        let soft: Vec<Finding> = new.into_iter().cloned().collect();
        let (old_records, new_records) = (records(&old)?, records(&model)?);
        let mut before = serde_json::Map::new();
        let mut after = serde_json::Map::new();
        for (id, r) in &new_records {
            let was = old_records.iter().find(|(i, _)| i == id).map(|(_, r)| r);
            if was != Some(r) {
                before.insert(id.to_string(), was.map_or(Ok(Value::Null), serde_json::to_value)?);
                after.insert(id.to_string(), serde_json::to_value(r)?);
            }
        }
        for (id, r) in &old_records {
            if !new_records.iter().any(|(i, _)| i == id) {
                before.insert(id.to_string(), serde_json::to_value(r)?);
                after.insert(id.to_string(), Value::Null);
            }
        }
        let mut change = serde_json::json!({ "ops": ops, "summaries": summaries, "before": before, "after": after });
        if let Some(n) = turn {
            change["turn"] = Value::from(n);
        }
        let operation = self.write_records(name, "change", by, change, &after, turn)?;
        Ok(Changed { operation, summaries, soft })
    }

    /// Undoes the schema's latest change not undone yet, if what it wrote is still there.
    ///
    /// # Errors
    /// When there is nothing to undo, the records changed since, there is no such schema, or the store fails.
    pub fn undo(&self, name: &str, by: &str) -> Result<Operation> {
        let log = self.operations(name)?;
        let undone = Self::undone(&log);
        let last = log
            .iter()
            .rev()
            .find(|o| o.kind == "change" && !undone.contains(&o.sequence))
            .ok_or_else(|| Error::Refused("there is no change to undo".to_string()))?;
        let (Some(before), Some(after)) = (last.change["before"].as_object(), last.change["after"].as_object()) else {
            return Err(Error::Refused(format!("change #{} cannot be undone", last.sequence)));
        };
        {
            let txn = self.db.begin_read()?;
            let objects = txn.open_table(OBJECTS)?;
            for (id, want) in after {
                let now: Value = match objects.get(format!("{name}/{id}").as_str())? {
                    Some(v) => serde_json::from_str(v.value())?,
                    None => Value::Null,
                };
                if &now != want {
                    return Err(Error::Refused(format!(
                        "`{id}` changed after change #{}: undo the later changes first",
                        last.sequence
                    )));
                }
            }
        }
        let change = serde_json::json!({ "undoes": last.sequence, "summaries": last.change["summaries"] });
        self.write_records(name, "undo", by, change, before, None)
    }

    /// The changes of the log that an undo or a rejected turn took back.
    fn undone(log: &[Operation]) -> Vec<u64> {
        let mut out = Vec::new();
        for o in log {
            if let Some(n) = o.change["undoes"].as_u64() {
                out.push(n);
            }
            if let Some(all) = o.change["undoes_all"].as_array() {
                out.extend(all.iter().filter_map(Value::as_u64));
            }
        }
        out
    }

    /// Opens a turn: the agent's changes for one prompt, summarised as it understood it.
    ///
    /// # Errors
    /// When there is no such schema, or the store fails.
    pub fn start_turn(&self, name: &str, summary: &str, by: &str) -> Result<Turn> {
        let txn = self.db.begin_write()?;
        let turn;
        {
            schema_info(&txn.open_table(SCHEMAS)?, name)?;
            let mut table = txn.open_table(TURNS)?;
            let (lo, hi) = prefix_range(name);
            let last = match table.range(lo.as_str()..hi.as_str())?.next_back().transpose()? {
                Some((_, v)) => serde_json::from_str::<Turn>(v.value())?.id,
                None => 0,
            };
            turn = Turn {
                id: last + 1,
                by: by.to_string(),
                summary: summary.to_string(),
                status: TurnStatus::Open,
                changes: Vec::new(),
                decided_by: None,
            };
            table.insert(proposal_key(name, turn.id).as_str(), serde_json::to_string(&turn)?.as_str())?;
        }
        txn.commit()?;
        Ok(turn)
    }

    /// The schema's turns, oldest first.
    ///
    /// # Errors
    /// When there is no such schema, the store fails or a record is not valid.
    pub fn turns(&self, name: &str) -> Result<Vec<Turn>> {
        let txn = self.db.begin_read()?;
        schema_info(&txn.open_table(SCHEMAS)?, name)?;
        let table = txn.open_table(TURNS)?;
        let (lo, hi) = prefix_range(name);
        let mut out = Vec::new();
        for entry in table.range(lo.as_str()..hi.as_str())? {
            let (_, v) = entry?;
            out.push(serde_json::from_str(v.value())?);
        }
        Ok(out)
    }

    /// Accepts an open turn: its changes stay, reviewed.
    ///
    /// # Errors
    /// When there is no such open turn, or the store fails.
    pub fn accept_turn(&self, name: &str, n: u64, by: &str) -> Result<Turn> {
        let txn = self.db.begin_write()?;
        let turn;
        let operation;
        {
            let mut table = txn.open_table(TURNS)?;
            let mut t = open_turn(&table, name, n)?;
            t.status = TurnStatus::Accepted;
            t.decided_by = Some(by.to_string());
            table.insert(proposal_key(name, n).as_str(), serde_json::to_string(&t)?.as_str())?;
            let mut ops = txn.open_table(OPERATIONS)?;
            let sequence = last_sequence(&ops, name)? + 1;
            operation = Operation {
                sequence,
                kind: "accept_turn".to_string(),
                by: by.to_string(),
                change: serde_json::json!({ "turn": n }),
            };
            ops.insert(operation_key(name, sequence).as_str(), serde_json::to_string(&operation)?.as_str())?;
            turn = t;
        }
        txn.commit()?;
        let _ = self.changes.send(Change { schema: name.to_string(), operation });
        Ok(turn)
    }

    /// Rejects an open turn: every change of it is taken back, newest first, in one transaction; refused, and
    /// nothing taken back, when anything it touched changed since.
    ///
    /// # Errors
    /// When there is no such open turn, its records changed since, or the store fails.
    pub fn reject_turn(&self, name: &str, n: u64, by: &str) -> Result<Turn> {
        let log = self.operations(name)?;
        let undone = Self::undone(&log);
        let turn = self
            .turns(name)?
            .into_iter()
            .find(|t| t.id == n)
            .ok_or_else(|| Error::Refused(format!("there is no turn {n}")))?;
        if turn.status != TurnStatus::Open {
            return Err(Error::Refused(format!("turn {n} is {:?}", turn.status).to_lowercase()));
        }
        let changes: Vec<&Operation> = turn
            .changes
            .iter()
            .rev()
            .filter(|s| !undone.contains(s))
            .filter_map(|s| log.iter().find(|o| o.sequence == *s))
            .collect();
        // Walk back from what is there now: each change must find what it left, then gives back what it found.
        let mut now: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
        {
            let txn = self.db.begin_read()?;
            let objects = txn.open_table(OBJECTS)?;
            for c in &changes {
                for id in c.change["after"].as_object().into_iter().flatten().map(|(k, _)| k) {
                    if !now.contains_key(id) {
                        let v = match objects.get(format!("{name}/{id}").as_str())? {
                            Some(v) => serde_json::from_str(v.value())?,
                            None => Value::Null,
                        };
                        now.insert(id.clone(), v);
                    }
                }
            }
        }
        for c in &changes {
            let (Some(before), Some(after)) = (c.change["before"].as_object(), c.change["after"].as_object()) else {
                return Err(Error::Refused(format!("change #{} cannot be taken back", c.sequence)));
            };
            for (id, want) in after {
                if now.get(id) != Some(want) {
                    return Err(Error::Refused(format!(
                        "`{id}` changed after change #{} of turn {n}: nothing was taken back",
                        c.sequence
                    )));
                }
            }
            for (id, was) in before {
                now.insert(id.clone(), was.clone());
            }
        }
        let records: serde_json::Map<String, Value> = now.into_iter().collect();
        let seqs: Vec<u64> = changes.iter().map(|c| c.sequence).collect();
        let change = serde_json::json!({ "turn": n, "undoes_all": seqs, "summaries": [format!("rejected turn {n}: {}", turn.summary)] });
        self.write_records(name, "reject_turn", by, change, &records, None)?;
        let txn = self.db.begin_write()?;
        let mut t = turn;
        {
            let mut table = txn.open_table(TURNS)?;
            t.status = TurnStatus::Rejected;
            t.decided_by = Some(by.to_string());
            table.insert(proposal_key(name, n).as_str(), serde_json::to_string(&t)?.as_str())?;
        }
        txn.commit()?;
        Ok(t)
    }

    /// Writes record values (null takes the record away) and logs the change, in one transaction.
    fn write_records(
        &self,
        name: &str,
        kind: &str,
        by: &str,
        change: Value,
        records: &serde_json::Map<String, Value>,
        turn: Option<u64>,
    ) -> Result<Operation> {
        let txn = self.db.begin_write()?;
        let operation;
        {
            schema_info(&txn.open_table(SCHEMAS)?, name)?;
            let mut objects = txn.open_table(OBJECTS)?;
            for (id, value) in records {
                let key = format!("{name}/{id}");
                if value.is_null() {
                    objects.remove(key.as_str())?;
                } else {
                    objects.insert(key.as_str(), serde_json::to_string(value)?.as_str())?;
                }
            }
            let mut ops = txn.open_table(OPERATIONS)?;
            let sequence = last_sequence(&ops, name)? + 1;
            operation = Operation { sequence, kind: kind.to_string(), by: by.to_string(), change };
            ops.insert(operation_key(name, sequence).as_str(), serde_json::to_string(&operation)?.as_str())?;
            if let Some(n) = turn {
                let mut turns = txn.open_table(TURNS)?;
                let mut t = open_turn(&turns, name, n)?;
                t.changes.push(sequence);
                turns.insert(proposal_key(name, n).as_str(), serde_json::to_string(&t)?.as_str())?;
            }
        }
        txn.commit()?;
        let _ = self.changes.send(Change { schema: name.to_string(), operation: operation.clone() });
        Ok(operation)
    }

    /// Reads the rules of `to`, applies `edit`, writes them back and logs the change, in one transaction.
    fn change_rules(
        &self,
        to: Rules<'_>,
        kind: &str,
        by: &str,
        change: Value,
        edit: impl FnOnce(&mut RuleSet) -> Result<()>,
    ) -> Result<Operation> {
        let key = to.key();
        let txn = self.db.begin_write()?;
        let operation;
        {
            if let Rules::Schema(name) = to {
                schema_info(&txn.open_table(SCHEMAS)?, name)?;
            }
            let mut table = txn.open_table(RULES)?;
            let mut set = read_rules(&table, &key)?;
            edit(&mut set)?;
            table.insert(key.as_str(), serde_json::to_string(&set)?.as_str())?;
            let mut ops = txn.open_table(OPERATIONS)?;
            let sequence = last_sequence(&ops, &key)? + 1;
            operation = Operation { sequence, kind: kind.to_string(), by: by.to_string(), change };
            ops.insert(operation_key(&key, sequence).as_str(), serde_json::to_string(&operation)?.as_str())?;
        }
        txn.commit()?;
        let _ = self.changes.send(Change { schema: key, operation: operation.clone() });
        Ok(operation)
    }
}

fn open_turn(table: &impl ReadableTable<&'static str, &'static str>, name: &str, n: u64) -> Result<Turn> {
    let t: Turn = match table.get(proposal_key(name, n).as_str())? {
        Some(v) => serde_json::from_str(v.value())?,
        None => return Err(Error::Refused(format!("there is no turn {n}"))),
    };
    if t.status == TurnStatus::Open {
        Ok(t)
    } else {
        Err(Error::Refused(format!("turn {n} is {:?}", t.status).to_lowercase()))
    }
}

fn read_rules(table: &impl ReadableTable<&'static str, &'static str>, key: &str) -> Result<RuleSet> {
    match table.get(key)? {
        Some(v) => Ok(serde_json::from_str(v.value())?),
        None => Ok(RuleSet::default()),
    }
}

fn valid_name(name: &str) -> Result<()> {
    let ok = name.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_');
    if ok { Ok(()) } else { Err(Error::BadName(name.to_string())) }
}

fn schema_info(schemas: &impl ReadableTable<&'static str, &'static str>, name: &str) -> Result<SchemaInfo> {
    let value = schemas.get(name)?.ok_or_else(|| Error::NoSchema(name.to_string()))?;
    Ok(serde_json::from_str(value.value())?)
}

/// Keys from `<name>/` up to, not including, `<name>0` (`0` sorts right after `/`).
fn prefix_range(name: &str) -> (String, String) {
    (format!("{name}/"), format!("{name}0"))
}

fn proposal_key(name: &str, id: u64) -> String {
    format!("{name}/{id:012}")
}

fn operation_key(name: &str, sequence: u64) -> String {
    format!("{name}/{sequence:012}")
}

fn last_sequence(ops: &impl ReadableTable<&'static str, &'static str>, name: &str) -> Result<u64> {
    let (lo, hi) = prefix_range(name);
    let last = ops.range(lo.as_str()..hi.as_str())?.next_back().transpose()?;
    match last {
        Some((_, v)) => Ok(serde_json::from_str::<Operation>(v.value())?.sequence),
        None => Ok(0),
    }
}

/// The model's top-level objects as records, keyed by id.
fn records(model: &Schema) -> Result<Vec<(Id, Record)>> {
    let doc = serde_json::to_value(model)?;
    let mut out = Vec::new();
    for section in SECTIONS {
        let Some(Value::Array(items)) = doc.get(section.key()) else { continue };
        for (position, object) in items.iter().enumerate() {
            let id: Id = serde_json::from_value(object.get("id").cloned().unwrap_or(Value::Null))?;
            out.push((id, Record { section, position, object: object.clone() }));
        }
    }
    Ok(out)
}
