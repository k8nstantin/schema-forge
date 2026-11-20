//! The embedded store (docs/store.md): one redb file of text keys to JSON values. The current model is kept
//! as one record per top-level object beside an append-only log of operations; every committed change is
//! announced to subscribers.

use std::path::Path;

use redb::{Database, ReadableDatabase, ReadableTable, TableDefinition};
use schema_forge_core::rules::{self, Group, Link, RuleSet, Scope};
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
#[derive(Debug, Serialize, Deserialize)]
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
        read_model(&txn.open_table(SCHEMAS)?, &txn.open_table(OBJECTS)?, name)
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
        rules::well_formed(rules::catalog(), &link).map_err(Error::Rule)?;
        match to {
            Rules::Schema(_) if link.at == Scope::Global => {
                return Err(Error::Rule("a global link goes to every schema, not one".to_string()));
            }
            Rules::Global if link.at != Scope::Global => {
                return Err(Error::Rule("a link for every schema is at the global level".to_string()));
            }
            _ => {}
        }
        let change = serde_json::to_value(&link)?;
        self.change_rules(to, "link_rule", by, change, |set, look| {
            look.admit(to, set, &link)?;
            set.links.push(link);
            Ok(())
        })
    }

    /// Links each of `packs` to the whole schema in one change, all or none. A pack already linked there or to
    /// every schema is left as it is, and so is one the schema switches off: that was the operator's choice.
    /// Returns the change, or `None` when every pack was in place.
    ///
    /// # Errors
    /// When a pack does not hold ([`Error::Rule`]), there is no such schema, or the store fails.
    pub fn link_packs(&self, name: &str, packs: &[&str], by: &str) -> Result<Option<Operation>> {
        let global = self.global_rules()?;
        let set = self.rules(name)?;
        let todo: Vec<&str> = packs.iter().copied().filter(|p| rules::pack_open(&global, &set, p)).collect();
        if todo.is_empty() {
            return Ok(None);
        }
        let change = serde_json::json!({ "packs": todo });
        self.change_rules(Rules::Schema(name), "link_packs", by, change, |set, look| {
            for p in &todo {
                let link = Link { rule: (*p).to_string(), at: Scope::Schema, off: false, locked: false, reason: None };
                look.admit(Rules::Schema(name), set, &link)?;
                set.links.push(link);
            }
            Ok(())
        })
        .map(Some)
    }

    /// Takes away the link or exception of `rule` at `at`.
    ///
    /// # Errors
    /// When there is none, there is no such schema, or the store fails.
    pub fn unlink_rule(&self, to: Rules<'_>, rule: &str, at: &Scope, by: &str) -> Result<Operation> {
        let change = serde_json::json!({ "rule": rule, "at": at });
        self.change_rules(to, "unlink_rule", by, change, |set, _| {
            let before = set.links.len();
            set.links.retain(|l| !(l.rule == rule && &l.at == at));
            if set.links.len() == before {
                return Err(Error::Rule(format!("`{rule}` is not linked at {}", rules::describe(at))));
            }
            Ok(())
        })
    }

    /// Makes a group of tables (`new`), or changes the tables of one there is. The exceptions linked to the group
    /// are checked again against its new tables.
    ///
    /// # Errors
    /// When a table is not in the schema, a new group's name is taken or a changed one is not there, an
    /// exception no longer holds, there is no such schema, or the store fails.
    pub fn set_group(&self, name: &str, group: Group, new: bool, by: &str) -> Result<Operation> {
        if group.name.trim().is_empty() {
            return Err(Error::Rule("a group needs a name".to_string()));
        }
        let change = serde_json::to_value(&group)?;
        self.change_rules(Rules::Schema(name), "set_group", by, change, |set, look| {
            let model = look.model(name)?;
            if let Some(t) = group.tables.iter().find(|t| !model.tables.iter().any(|m| &m.id == *t)) {
                return Err(Error::Rule(format!("there is no table `{t}` in `{name}`")));
            }
            let there = set.groups.iter().any(|g| g.name == group.name);
            if new && there {
                return Err(Error::Rule(format!("there is a group `{}` already", group.name)));
            }
            if !new && !there {
                return Err(Error::Rule(format!("there is no group `{}`", group.name)));
            }
            let at = Scope::Group { group: group.name.clone() };
            set.groups.retain(|g| g.name != group.name);
            set.groups.push(group);
            let off: Vec<Link> = set.links.iter().filter(|l| l.at == at && l.off).cloned().collect();
            for l in &off {
                let mut rest = set.clone();
                rest.links.retain(|x| !(x.rule == l.rule && x.at == l.at));
                look.admit(Rules::Schema(name), &rest, l)?;
            }
            Ok(())
        })
    }

    /// Takes away a group no rule is linked to.
    ///
    /// # Errors
    /// When rules are linked to it, there is no such group or schema, or the store fails.
    pub fn remove_group(&self, name: &str, group: &str, by: &str) -> Result<Operation> {
        let change = serde_json::json!({ "group": group });
        self.change_rules(Rules::Schema(name), "remove_group", by, change, |set, _| {
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

    /// Reads the rules of `to`, applies `edit`, writes them back and logs the change, in one transaction.
    fn change_rules(
        &self,
        to: Rules<'_>,
        kind: &str,
        by: &str,
        change: Value,
        edit: impl FnOnce(&mut RuleSet, &Look<'_, '_>) -> Result<()>,
    ) -> Result<Operation> {
        let key = to.key();
        let txn = self.db.begin_write()?;
        let operation;
        {
            let schemas = txn.open_table(SCHEMAS)?;
            if let Rules::Schema(name) = to {
                schema_info(&schemas, name)?;
            }
            let objects = txn.open_table(OBJECTS)?;
            let mut table = txn.open_table(RULES)?;
            let mut set = read_rules(&table, &key)?;
            edit(&mut set, &Look { schemas: &schemas, objects: &objects, rules: &table })?;
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

/// The schema `name`'s model, read back from its records in `objects`.
fn read_model(
    schemas: &impl ReadableTable<&'static str, &'static str>,
    objects: &impl ReadableTable<&'static str, &'static str>,
    name: &str,
) -> Result<Schema> {
    let info = schema_info(schemas, name)?;
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

/// What a rules change reads, inside its own write transaction, so a check and the write it allows see the
/// same store.
struct Look<'a, 't> {
    schemas: &'a redb::Table<'t, &'static str, &'static str>,
    objects: &'a redb::Table<'t, &'static str, &'static str>,
    rules: &'a redb::Table<'t, &'static str, &'static str>,
}

impl Look<'_, '_> {
    fn model(&self, name: &str) -> Result<Schema> {
        read_model(self.schemas, self.objects, name)
    }

    /// Checks `link` may be added to `set`, the rules of `to`: against that schema, or for a global link
    /// against every schema of the workspace.
    fn admit(&self, to: Rules<'_>, set: &RuleSet, link: &Link) -> Result<()> {
        let cat = rules::catalog();
        match to {
            Rules::Schema(name) => {
                let global = read_rules(self.rules, GLOBAL)?.links;
                rules::admit(cat, &self.model(name)?, &global, set, link).map_err(Error::Rule)
            }
            Rules::Global => {
                for entry in self.schemas.iter()? {
                    let (k, _) = entry?;
                    let name = k.value();
                    let own = read_rules(self.rules, name)?;
                    rules::admit(cat, &self.model(name)?, &set.links, &own, link)
                        .map_err(|e| Error::Rule(format!("{name}: {e}")))?;
                }
                Ok(())
            }
        }
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
