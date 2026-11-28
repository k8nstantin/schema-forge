//! From what was read to the store's rows: every column filled as the mapping of the task says, from the source it names.
//! Each object is given its UUIDv7 once, in a map keyed by a typed key (`ObjectKey`), and every reference (a column's
//! table, an index's columns, a key's referenced table and columns, a view's uses, a routine's libraries, a privilege's
//! object, a grant's role) is resolved through that map. A reference to nothing the catalogs list is left out for a view's
//! uses and is an error naming it anywhere else.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Display;
use std::sync::LazyLock;

use regex::Regex;
use schema_forge_engine::EngineError;
use uuid::Uuid;

use crate::catalog::{
    ColumnRow, ForeignKeyColumn, GrantRow, PartitionRow, Statistic, TableRow, is_system_account, split_grantee,
};
use crate::keys::{AccountName, Kind, ObjectKey, Scope, q};
use crate::read::Snapshot;
use crate::rows::{
    Accounts, ColumnOptions, Columns, Components, CompressionDictionaries, ConstraintColumns, Constraints, Databases,
    Dependencies, Events, IndexOptions, IndexPartOptions, IndexParts, Indexes, Libraries, LoadableFunctions,
    Namespaces, Objects, Partitionings, Partitions, Privileges, ResourceGroups, RoleGrants, RoutineParameters,
    Routines, Rows, Servers, SpatialReferenceSystems, TableOptions, Tablespaces, Triggers, Views,
};
use crate::show::{TableShow, UserShow, ViewShow};

/// The engine's name in `cortex.objects.engine`.
const ENGINE: &str = "mysql";

static CURRENT_TIMESTAMP: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^(CURRENT_TIMESTAMP|NOW)(\(\d*\))?$").expect("a fixed pattern"));
static ON_UPDATE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\bon update (current_timestamp(?:\(\d*\))?|now(?:\(\d*\))?)").expect("a fixed pattern")
});

// --- small helpers ---------------------------------------------------------------------------------------------------------

/// A reference to something the catalogs do not list.
fn missing(what: impl Display, target: impl Display) -> EngineError {
    EngineError::Source(format!(
        "{what} refers to {target}, which the catalogs of the server do not list"
    ))
}

/// What the server gives for "none", an empty string, stored as NULL.
fn some(text: &str) -> Option<String> {
    (!text.is_empty()).then(|| text.to_string())
}

fn int32(value: i64, what: impl Display) -> Result<i32, EngineError> {
    i32::try_from(value).map_err(|_| EngineError::Source(format!("{what}: {value} is out of range")))
}

fn position(n: usize) -> i32 {
    i32::try_from(n).unwrap_or(i32::MAX)
}

/// A definer as MySQL writes it: `user`@`host`.
fn definer(raw: &str) -> String {
    let account = AccountName::from_object_name(raw);
    format!("{}@{}", q(&account.user), q(&account.host))
}

/// The words `key=value` of `TABLES.CREATE_OPTIONS`, by lower-cased key, the quotes of a value removed.
fn create_options(text: &str) -> HashMap<String, String> {
    text.split_whitespace()
        .filter_map(|word| word.split_once('='))
        .map(|(k, v)| (k.to_lowercase(), v.trim_matches(|c| c == '"' || c == '\'').to_string()))
        .collect()
}

fn rule(text: &str, what: &str) -> Result<String, EngineError> {
    Ok(match text {
        "CASCADE" => "cascade",
        "SET NULL" => "set_null",
        "SET DEFAULT" => "set_default",
        "RESTRICT" => "restrict",
        "NO ACTION" => "no_action",
        other => {
            return Err(EngineError::Source(format!(
                "{what}: the rule `{other}` is not one MySQL has"
            )));
        }
    }
    .to_string())
}

/// An object planned: its comment and the object it belongs to.
struct Planned {
    comment: Option<String>,
    parent: Option<ObjectKey>,
}

/// The tables and columns of the design as built so far, for the references that follow.
struct Builder<'a> {
    snap: &'a Snapshot,
    design: Uuid,
    /// 5.7 lists no tables a view reads and has no roles.
    five_seven: bool,
    rows: Rows,
    server: Uuid,
    databases: HashMap<String, Uuid>,
    objects: HashMap<ObjectKey, Uuid>,
    accounts: HashMap<AccountName, Uuid>,
    columns: HashMap<(Uuid, String), Uuid>,
}

/// Builds every row of a design from what was read.
pub fn build(snapshot: &Snapshot, design: Uuid) -> Result<Rows, EngineError> {
    let mut b = Builder {
        snap: snapshot,
        design,
        five_seven: snapshot.identity.probe.version == "5.7",
        rows: Rows::default(),
        server: Uuid::now_v7(),
        databases: HashMap::new(),
        objects: HashMap::new(),
        accounts: HashMap::new(),
        columns: HashMap::new(),
    };
    b.namespaces()?;
    b.objects()?;
    b.columns()?;
    b.indexes_and_constraints()?;
    b.dependencies()?;
    b.table_options()?;
    b.partitioning()?;
    b.programs()?;
    b.accounts_and_grants()?;
    b.server_objects()?;
    Ok(b.rows)
}

impl<'a> Builder<'a> {
    fn id(&self, what: impl Display, key: &ObjectKey) -> Result<Uuid, EngineError> {
        self.objects.get(key).copied().ok_or_else(|| missing(what, key))
    }

    /// The id of a table or a view of a database, if the catalogs list one.
    fn table_or_view(&self, database: &str, name: &str) -> Option<(Uuid, Kind)> {
        [Kind::Table, Kind::View].into_iter().find_map(|kind| {
            self.objects
                .get(&ObjectKey::in_database(database, kind, name))
                .map(|id| (*id, kind))
        })
    }

    fn table_show(&self, key: &ObjectKey) -> Result<&'a TableShow, EngineError> {
        self.snap
            .shows
            .tables
            .get(key)
            .ok_or_else(|| missing("the import", format!("SHOW CREATE TABLE of {key}")))
    }

    // --- namespaces ----------------------------------------------------------------------------------------------------------

    fn namespaces(&mut self) -> Result<(), EngineError> {
        let (design, ident, catalog) = (self.design, &self.snap.identity, &self.snap.catalog);
        let server = self.server;
        let ns = &mut self.rows.namespaces;
        push_namespace(ns, server, design, None, "server", 1);
        self.rows.instances.id.push(server);
        self.rows.instances.design.push(design);
        self.rows.instances.version.push(ident.full.clone());
        self.rows.instances.character_set.push(ident.character_set.clone());
        self.rows.instances.collation.push(ident.collation.clone());
        self.rows
            .instances
            .lower_case_table_names
            .push(int32(ident.lower_case_table_names, "@@lower_case_table_names")?);
        self.rows.instances.sql_mode.push(ident.sql_mode.clone());
        for (n, schema) in catalog.schemata.iter().enumerate() {
            let id = Uuid::now_v7();
            push_namespace(
                &mut self.rows.namespaces,
                id,
                design,
                Some(server),
                &schema.schema_name,
                position(n + 1),
            );
            self.databases.insert(schema.schema_name.clone(), id);
            let extension = catalog
                .schemata_extensions
                .iter()
                .find(|e| e.schema_name == schema.schema_name);
            let d: &mut Databases = &mut self.rows.databases;
            d.id.push(id);
            d.design.push(design);
            d.character_set.push(schema.default_character_set_name.clone());
            d.collation.push(schema.default_collation_name.clone());
            d.encryption
                .push(schema.default_encryption.as_ref().map(|e| e == "YES"));
            d.read_only.push(extension.map(|e| {
                e.options
                    .as_deref()
                    .is_some_and(|o| o.split(',').any(|part| part.trim() == "READ ONLY=1"))
            }));
        }
        Ok(())
    }

    // --- objects -------------------------------------------------------------------------------------------------------------

    fn account_kind(&self, show: &UserShow) -> Kind {
        let made_by_create_role =
            show.locked && show.password_expire.as_deref() == Some("") && show.auth_string.is_none();
        if !self.five_seven && made_by_create_role {
            Kind::Role
        } else {
            Kind::Account
        }
    }

    fn objects(&mut self) -> Result<(), EngineError> {
        let catalog = &self.snap.catalog;
        let mut planned: BTreeMap<ObjectKey, Planned> = BTreeMap::new();
        let mut plan = |key: ObjectKey, comment: Option<String>, parent: Option<ObjectKey>| {
            planned.insert(key, Planned { comment, parent });
        };
        for t in &catalog.tables {
            plan(
                ObjectKey::in_database(&t.table_schema, Kind::Table, &t.table_name),
                some(&t.table_comment),
                None,
            );
        }
        for v in &catalog.views {
            plan(
                ObjectKey::in_database(&v.table_schema, Kind::View, &v.table_name),
                None,
                None,
            );
        }
        for r in &catalog.routines {
            let kind = routine_kind(&r.routine_type)?;
            plan(
                ObjectKey::in_database(&r.routine_schema, kind, &r.routine_name),
                some(&r.routine_comment),
                None,
            );
        }
        for t in &catalog.triggers {
            let table = ObjectKey::in_database(&t.trigger_schema, Kind::Table, &t.event_object_table);
            plan(
                ObjectKey::in_database(&t.trigger_schema, Kind::Trigger, &t.trigger_name),
                None,
                Some(table),
            );
        }
        for e in &catalog.events {
            plan(
                ObjectKey::in_database(&e.event_schema, Kind::Event, &e.event_name),
                some(&e.event_comment),
                None,
            );
        }
        for l in &catalog.libraries {
            plan(
                ObjectKey::in_database(&l.library_schema, Kind::Library, &l.library_name),
                l.library_comment.as_deref().and_then(some),
                None,
            );
        }
        for a in &catalog.accounts {
            let name = AccountName::new(&a.user, &a.host);
            let show = self
                .snap
                .shows
                .users
                .get(&name)
                .ok_or_else(|| missing("the import", format!("SHOW CREATE USER of {}", name.object_name())))?;
            let kind = self.account_kind(show);
            plan(ObjectKey::of_server(kind, &name.object_name()), None, None);
        }
        for t in &catalog.tablespaces {
            plan(ObjectKey::of_server(Kind::Tablespace, &t.name), None, None);
        }
        for s in &catalog.spatial_reference_systems {
            plan(
                ObjectKey::of_server(Kind::SpatialReferenceSystem, &s.srs_name),
                None,
                None,
            );
        }
        for s in &catalog.servers {
            plan(ObjectKey::of_server(Kind::Server, &s.server_name), None, None);
        }
        for g in &catalog.resource_groups {
            plan(
                ObjectKey::of_server(Kind::ResourceGroup, &g.resource_group_name),
                None,
                None,
            );
        }
        for c in &catalog.components {
            plan(ObjectKey::of_server(Kind::Component, c), None, None);
        }
        for f in &catalog.loadable_functions {
            plan(ObjectKey::of_server(Kind::LoadableFunction, &f.name), None, None);
        }
        for d in &catalog.compression_dictionaries {
            plan(ObjectKey::of_server(Kind::CompressionDictionary, &d.name), None, None);
        }
        // every object is given its id once, before anything refers to it
        for key in planned.keys() {
            self.objects.insert(key.clone(), Uuid::now_v7());
        }
        let mut next: HashMap<Scope, usize> = HashMap::new();
        for (key, plan) in &planned {
            let namespace = match &key.scope {
                Scope::Server => self.server,
                Scope::Database(d) => *self
                    .databases
                    .get(d)
                    .ok_or_else(|| missing(key, format!("the database {d}")))?,
            };
            let parent = plan.parent.as_ref().map(|p| self.id(key, p)).transpose()?;
            let place = next.entry(key.scope.clone()).or_insert(0);
            *place += 1;
            let o: &mut Objects = &mut self.rows.objects;
            o.id.push(self.objects[key]);
            o.design.push(self.design);
            o.engine.push(ENGINE.to_string());
            o.namespace.push(namespace);
            o.kind.push(key.kind.as_str().to_string());
            o.name.push(key.name.clone());
            o.signature.push(String::new());
            o.parent.push(parent);
            o.position.push(position(*place));
            o.comment.push(plan.comment.clone());
            o.notes.push(None);
        }
        Ok(())
    }

    // --- columns -------------------------------------------------------------------------------------------------------------

    fn columns(&mut self) -> Result<(), EngineError> {
        let catalog = &self.snap.catalog;
        let tables: HashMap<(&str, &str), &TableRow> = catalog
            .tables
            .iter()
            .map(|t| ((t.table_schema.as_str(), t.table_name.as_str()), t))
            .collect();
        let mut groups: BTreeMap<(&str, &str), Vec<&ColumnRow>> = BTreeMap::new();
        for c in &catalog.columns {
            groups
                .entry((c.table_schema.as_str(), c.table_name.as_str()))
                .or_default()
                .push(c);
        }
        for ((database, table), columns) in groups {
            let (owner, kind) = self
                .table_or_view(database, table)
                .ok_or_else(|| missing(format!("a column of {database}.{table}"), format!("{database}.{table}")))?;
            let table_key = ObjectKey::in_database(database, Kind::Table, table);
            let show = (kind == Kind::Table).then(|| self.table_show(&table_key)).transpose()?;
            let table_collation = tables
                .get(&(database, table))
                .and_then(|t| t.table_collation.as_deref());
            for c in columns {
                let id = Uuid::now_v7();
                self.columns.insert((owner, c.column_name.clone()), id);
                let shown = show.and_then(|s| s.columns.get(&c.column_name));
                let stored = c.extra.contains("STORED GENERATED");
                let generated = stored || c.extra.contains("VIRTUAL GENERATED");
                let expression = if generated {
                    Some(shown.and_then(|s| s.generated_expression.clone()).ok_or_else(|| {
                        missing(
                            format!("the generated column {database}.{table}.{}", c.column_name),
                            "its expression in SHOW CREATE TABLE",
                        )
                    })?)
                } else {
                    None
                };
                let collation = match kind {
                    Kind::View => c.collation_name.clone(),
                    _ => c
                        .collation_name
                        .clone()
                        .filter(|name| Some(name.as_str()) != table_collation),
                };
                let default_is_expression = c.extra.contains("DEFAULT_GENERATED")
                    || (self.five_seven
                        && c.column_default
                            .as_deref()
                            .is_some_and(|d| CURRENT_TIMESTAMP.is_match(d)));
                let cc: &mut Columns = &mut self.rows.columns;
                cc.id.push(id);
                cc.design.push(self.design);
                cc.object.push(owner);
                cc.position.push(int32(c.ordinal_position, &c.column_name)?);
                cc.name.push(c.column_name.clone());
                cc.r#type.push(c.column_type.clone());
                cc.nullable.push(c.is_nullable);
                cc.default_value
                    .push(if generated { None } else { c.column_default.clone() });
                cc.generated_expression.push(expression);
                cc.generated_stored.push(generated.then_some(stored));
                cc.comment.push(some(&c.column_comment));
                let stored_collation = collation.is_some();
                cc.collation.push(collation);
                let dictionary = shown
                    .and_then(|s| s.compression_dictionary.as_deref())
                    .map(|name| {
                        self.objects
                            .get(&ObjectKey::of_server(Kind::CompressionDictionary, name))
                            .copied()
                            .ok_or_else(|| {
                                missing(
                                    format!("the column {database}.{table}.{}", c.column_name),
                                    format!("the compression dictionary {name}"),
                                )
                            })
                    })
                    .transpose()?;
                let o: &mut ColumnOptions = &mut self.rows.column_options;
                o.id.push(id);
                o.design.push(self.design);
                o.character_set.push(if stored_collation {
                    c.character_set_name.clone()
                } else {
                    None
                });
                o.default_is_expression.push(default_is_expression);
                o.on_update.push(
                    ON_UPDATE
                        .captures(&c.extra)
                        .map(|m| m[1].to_uppercase().replace("NOW", "CURRENT_TIMESTAMP")),
                );
                o.auto_increment.push(c.extra.contains("auto_increment"));
                o.invisible.push(c.extra.contains("INVISIBLE"));
                o.srid.push(c.srs_id.map(|s| int32(s, "SRS_ID")).transpose()?);
                o.column_format.push(shown.and_then(|s| s.column_format.clone()));
                o.storage.push(shown.and_then(|s| s.storage.clone()));
                o.compression_dictionary.push(dictionary);
                o.engine_attribute.push(shown.and_then(|s| s.engine_attribute.clone()));
                o.secondary_engine_attribute
                    .push(shown.and_then(|s| s.secondary_engine_attribute.clone()));
            }
        }
        Ok(())
    }

    // --- indexes and constraints ---------------------------------------------------------------------------------------------------

    fn indexes_and_constraints(&mut self) -> Result<(), EngineError> {
        let catalog = &self.snap.catalog;
        let mut statistics: BTreeMap<(&str, &str), BTreeMap<&str, Vec<&Statistic>>> = BTreeMap::new();
        for s in &catalog.statistics {
            statistics
                .entry((s.table_schema.as_str(), s.table_name.as_str()))
                .or_default()
                .entry(s.index_name.as_str())
                .or_default()
                .push(s);
        }
        let mut foreign: BTreeMap<(&str, &str), BTreeMap<&str, Vec<&ForeignKeyColumn>>> = BTreeMap::new();
        for f in &catalog.foreign_keys {
            foreign
                .entry((f.table_schema.as_str(), f.table_name.as_str()))
                .or_default()
                .entry(f.constraint_name.as_str())
                .or_default()
                .push(f);
        }
        let mut tables: BTreeSet<(&str, &str)> = statistics.keys().copied().collect();
        tables.extend(foreign.keys().copied());
        tables.extend(
            catalog
                .checks
                .iter()
                .map(|c| (c.table_schema.as_str(), c.table_name.as_str())),
        );
        for (database, table) in tables {
            let key = ObjectKey::in_database(database, Kind::Table, table);
            let owner = self.id("an index or key", &key)?;
            let show = self.table_show(&key)?;
            let what = |name: &str| format!("{name} of {database}.{table}");
            let mut next_constraint = 0;
            // indexes, in the order SHOW CREATE TABLE lists them
            let mut indexes: Vec<(&str, &Vec<&Statistic>)> = statistics
                .get(&(database, table))
                .map(|m| m.iter().map(|(n, p)| (*n, p)).collect())
                .unwrap_or_default();
            let mut ordered = Vec::with_capacity(indexes.len());
            for shown in &show.indexes {
                if let Some(at) = indexes.iter().position(|(n, _)| *n == shown.name) {
                    ordered.push((indexes.remove(at), shown));
                }
            }
            if let Some((name, _)) = indexes.first() {
                return Err(missing(what(name), "an index SHOW CREATE TABLE lists"));
            }
            for (n, ((name, parts), shown)) in ordered.into_iter().enumerate() {
                let first = parts[0];
                let index_id = Uuid::now_v7();
                let ix: &mut Indexes = &mut self.rows.indexes;
                ix.id.push(index_id);
                ix.design.push(self.design);
                ix.object.push(owner);
                ix.position.push(position(n + 1));
                ix.name.push(name.to_string());
                ix.unique.push(!first.non_unique);
                ix.method.push(shown.method.clone());
                ix.condition.push(None);
                ix.comment.push(some(&first.index_comment));
                let kind = match first.index_type.as_str() {
                    "FULLTEXT" => "fulltext",
                    "SPATIAL" => "spatial",
                    _ => "index",
                };
                let io: &mut IndexOptions = &mut self.rows.index_options;
                io.id.push(index_id);
                io.design.push(self.design);
                io.kind.push(kind.to_string());
                io.parser.push(shown.parser.clone());
                io.key_block_size
                    .push(shown.key_block_size.map(|k| int32(k, what(name))).transpose()?);
                io.invisible.push(first.is_visible.as_deref() == Some("NO"));
                io.engine_attribute.push(shown.engine_attribute.clone());
                io.secondary_engine_attribute
                    .push(shown.secondary_engine_attribute.clone());
                let mut part_columns = Vec::with_capacity(parts.len());
                for p in parts {
                    let column = p
                        .column_name
                        .as_deref()
                        .map(|c| {
                            self.columns
                                .get(&(owner, c.to_string()))
                                .copied()
                                .ok_or_else(|| missing(what(name), format!("the column {c}")))
                        })
                        .transpose()?;
                    part_columns.push(column);
                    let part_id = Uuid::now_v7();
                    let ip: &mut IndexParts = &mut self.rows.index_parts;
                    ip.id.push(part_id);
                    ip.design.push(self.design);
                    ip.index.push(index_id);
                    ip.position.push(int32(p.seq_in_index, what(name))?);
                    ip.column.push(column);
                    ip.expression
                        .push(if column.is_some() { None } else { p.expression.clone() });
                    ip.descending.push(p.collation.as_deref() == Some("D"));
                    ip.included.push(false);
                    if let (Some(prefix), false) = (p.sub_part, kind == "spatial") {
                        let po: &mut IndexPartOptions = &mut self.rows.index_part_options;
                        po.id.push(part_id);
                        po.design.push(self.design);
                        po.prefix_length.push(int32(prefix, what(name))?);
                    }
                }
                // a primary or unique key of columns is a constraint of the table
                if !first.non_unique && part_columns.iter().all(Option::is_some) {
                    next_constraint += 1;
                    let id = self.push_constraint(
                        owner,
                        next_constraint,
                        Some(name.to_string()),
                        if name == "PRIMARY" { "primary" } else { "unique" },
                        None,
                        (None, None, None),
                    );
                    for (i, column) in part_columns.into_iter().flatten().enumerate() {
                        self.push_constraint_column(id, position(i + 1), column, None);
                    }
                }
            }
            // foreign keys, then checks, each in the order SHOW CREATE TABLE lists them
            let listed = |name: &str| show.constraints.iter().position(|c| c == name);
            let mut keys: Vec<(&str, &Vec<&ForeignKeyColumn>)> = foreign
                .get(&(database, table))
                .map(|m| m.iter().map(|(n, p)| (*n, p)).collect())
                .unwrap_or_default();
            keys.sort_by_key(|(name, _)| listed(name).unwrap_or(usize::MAX));
            for (name, parts) in keys {
                if listed(name).is_none() {
                    return Err(missing(what(name), "a constraint SHOW CREATE TABLE lists"));
                }
                let first = parts[0];
                let target = ObjectKey::in_database(
                    &first.referenced_table_schema,
                    Kind::Table,
                    &first.referenced_table_name,
                );
                let to_object = self.id(format!("the foreign key {}", what(name)), &target)?;
                let on_delete = rule(&first.delete_rule, &what(name))?;
                let on_update = rule(&first.update_rule, &what(name))?;
                next_constraint += 1;
                let id = self.push_constraint(
                    owner,
                    next_constraint,
                    Some(name.to_string()),
                    "foreign",
                    None,
                    (Some(to_object), Some(on_delete), Some(on_update)),
                );
                for p in parts {
                    let column = self
                        .columns
                        .get(&(owner, p.column_name.clone()))
                        .copied()
                        .ok_or_else(|| missing(what(name), format!("the column {}", p.column_name)))?;
                    let to_column = self
                        .columns
                        .get(&(to_object, p.referenced_column_name.clone()))
                        .copied()
                        .ok_or_else(|| {
                            missing(
                                format!("the foreign key {}", what(name)),
                                format!("the column {}", p.referenced_column_name),
                            )
                        })?;
                    self.push_constraint_column(id, int32(p.ordinal_position, what(name))?, column, Some(to_column));
                }
            }
            let mut checks: Vec<_> = catalog
                .checks
                .iter()
                .filter(|c| c.table_schema == database && c.table_name == table)
                .collect();
            checks.sort_by_key(|c| listed(&c.constraint_name).unwrap_or(usize::MAX));
            for c in checks {
                if listed(&c.constraint_name).is_none() {
                    return Err(missing(
                        what(&c.constraint_name),
                        "a constraint SHOW CREATE TABLE lists",
                    ));
                }
                next_constraint += 1;
                self.push_constraint(
                    owner,
                    next_constraint,
                    Some(c.constraint_name.clone()),
                    "check",
                    Some(c.check_clause.clone()),
                    (None, None, None),
                );
                // a check can be declared and not enforced
                if let Some(last) = self.rows.constraints.enforced.last_mut() {
                    *last = c.enforced;
                }
            }
        }
        Ok(())
    }

    fn push_constraint(
        &mut self,
        object: Uuid,
        position: i32,
        name: Option<String>,
        kind: &str,
        expression: Option<String>,
        (to_object, on_delete, on_update): (Option<Uuid>, Option<String>, Option<String>),
    ) -> Uuid {
        let id = Uuid::now_v7();
        let c: &mut Constraints = &mut self.rows.constraints;
        c.id.push(id);
        c.design.push(self.design);
        c.object.push(object);
        c.position.push(position);
        c.name.push(name);
        c.kind.push(kind.to_string());
        c.expression.push(expression);
        c.to_object.push(to_object);
        c.on_delete.push(on_delete);
        c.on_update.push(on_update);
        c.enforced.push(true);
        c.deferrable.push(false);
        c.initially_deferred.push(false);
        id
    }

    fn push_constraint_column(&mut self, constraint: Uuid, position: i32, column: Uuid, to_column: Option<Uuid>) {
        let c: &mut ConstraintColumns = &mut self.rows.constraint_columns;
        c.id.push(Uuid::now_v7());
        c.design.push(self.design);
        c.constraint.push(constraint);
        c.position.push(position);
        c.column.push(column);
        c.to_column.push(to_column);
    }

    // --- dependencies --------------------------------------------------------------------------------------------------------

    fn push_dependency(&mut self, object: Uuid, uses: Uuid, as_: &str, position: usize) {
        let d: &mut Dependencies = &mut self.rows.dependencies;
        d.id.push(Uuid::now_v7());
        d.design.push(self.design);
        d.object.push(object);
        d.uses.push(uses);
        d.r#as.push(as_.to_string());
        d.position.push(self::position(position));
    }

    fn dependencies(&mut self) -> Result<(), EngineError> {
        let catalog = &self.snap.catalog;
        // what a view reads: the server's list (8.0.13 and later), or the names its definition qualifies (5.7)
        for v in &catalog.views {
            let key = ObjectKey::in_database(&v.table_schema, Kind::View, &v.table_name);
            let view = self.id("a view", &key)?;
            let reads: Vec<(&str, &str)> = if self.five_seven {
                self.snap.shows.views.get(&key).map_or_else(Vec::new, |s: &ViewShow| {
                    s.references.iter().map(|(d, n)| (d.as_str(), n.as_str())).collect()
                })
            } else {
                catalog
                    .view_tables
                    .iter()
                    .filter(|u| u.view_schema == v.table_schema && u.view_name == v.table_name)
                    .map(|u| (u.table_schema.as_str(), u.table_name.as_str()))
                    .collect()
            };
            let used: BTreeSet<(&str, &str)> = reads.into_iter().collect();
            let found: Vec<Uuid> = used
                .into_iter()
                .filter_map(|(d, n)| self.table_or_view(d, n))
                .map(|(id, _)| id)
                .filter(|id| *id != view)
                .collect();
            for (n, uses) in found.into_iter().enumerate() {
                self.push_dependency(view, uses, "reads", n + 1);
            }
        }
        // a MERGE table's tables, in the order its statement names them
        for t in &catalog.tables {
            let key = ObjectKey::in_database(&t.table_schema, Kind::Table, &t.table_name);
            let union = self.table_show(&key)?.options.union.clone();
            let owner = self.id("a table", &key)?;
            for (n, name) in union.iter().enumerate() {
                let target = ObjectKey::in_database(&t.table_schema, Kind::Table, name);
                let uses = self.id(format!("the MERGE table {key}"), &target)?;
                self.push_dependency(owner, uses, "union", n + 1);
            }
        }
        // the libraries a routine uses
        let mut libraries: BTreeMap<ObjectKey, BTreeSet<ObjectKey>> = BTreeMap::new();
        for r in &catalog.routine_libraries {
            let routine = ObjectKey::in_database(&r.routine_schema, routine_kind(&r.routine_type)?, &r.routine_name);
            let library = ObjectKey::in_database(&r.library_schema, Kind::Library, &r.library_name);
            libraries.entry(routine).or_default().insert(library);
        }
        for (routine, used) in libraries {
            let owner = self.id("a routine", &routine)?;
            for (n, library) in used.iter().enumerate() {
                let uses = self.id(format!("the routine {routine}"), library)?;
                self.push_dependency(owner, uses, "library", n + 1);
            }
        }
        Ok(())
    }

    // --- tables --------------------------------------------------------------------------------------------------------------

    fn table_options(&mut self) -> Result<(), EngineError> {
        let catalog = &self.snap.catalog;
        for t in &catalog.tables {
            let key = ObjectKey::in_database(&t.table_schema, Kind::Table, &t.table_name);
            let id = self.id("a table", &key)?;
            let show = self.table_show(&key)?;
            let options = create_options(t.create_options.as_deref().unwrap_or_default());
            let number = |name: &str| -> Result<Option<i64>, EngineError> {
                options
                    .get(name)
                    .map(|v| {
                        v.parse::<i64>()
                            .map_err(|_| missing(&key, format!("{name}={v}, not a number")))
                    })
                    .transpose()
            };
            let upper = |name: &str| options.get(name).map(|v| v.to_uppercase());
            let connection = show
                .options
                .connection
                .as_deref()
                .map(|c| {
                    if c.contains("://") {
                        Err(EngineError::Unsupported(format!(
                            "the table {key} connects with a connection string, which is never kept (it may carry a password): \
                             make a server for it with CREATE SERVER and name it"
                        )))
                    } else {
                        Ok(c.split('/').next().unwrap_or(c).to_string())
                    }
                })
                .transpose()?;
            let engine = t
                .engine
                .clone()
                .ok_or_else(|| missing(&key, "a storage engine in TABLES.ENGINE"))?;
            let collation = t
                .table_collation
                .clone()
                .ok_or_else(|| missing(&key, "a collation in TABLES.TABLE_COLLATION"))?;
            let o: &mut TableOptions = &mut self.rows.tables;
            o.id.push(id);
            o.design.push(self.design);
            o.engine.push(engine);
            o.collation.push(collation);
            o.row_format.push(options.get("row_format").cloned());
            o.auto_increment.push(show.options.auto_increment);
            o.avg_row_length.push(number("avg_row_length")?);
            o.min_rows.push(number("min_rows")?);
            o.max_rows.push(number("max_rows")?);
            o.pack_keys.push(upper("pack_keys"));
            o.checksum.push(options.get("checksum").map(|v| v == "1"));
            o.delay_key_write.push(options.get("delay_key_write").map(|v| v == "1"));
            o.key_block_size
                .push(number("key_block_size")?.map(|k| int32(k, &key)).transpose()?);
            o.stats_persistent.push(upper("stats_persistent"));
            o.stats_auto_recalc.push(upper("stats_auto_recalc"));
            o.stats_sample_pages.push(upper("stats_sample_pages"));
            o.compression.push(options.get("compression").cloned());
            o.encryption
                .push(options.get("encryption").map(|v| v.eq_ignore_ascii_case("Y")));
            o.tablespace.push(show.options.tablespace.clone());
            o.storage.push(show.options.storage.clone());
            o.data_directory.push(show.options.data_directory.clone());
            o.index_directory.push(show.options.index_directory.clone());
            o.autoextend_size.push(options.get("autoextend_size").cloned());
            o.engine_attribute.push(show.options.engine_attribute.clone());
            o.secondary_engine.push(show.options.secondary_engine.clone());
            o.secondary_engine_attribute
                .push(show.options.secondary_engine_attribute.clone());
            o.insert_method.push(show.options.insert_method.clone());
            o.connection.push(connection);
        }
        Ok(())
    }

    fn partitioning(&mut self) -> Result<(), EngineError> {
        let catalog = &self.snap.catalog;
        let mut groups: BTreeMap<(&str, &str), Vec<&PartitionRow>> = BTreeMap::new();
        for p in &catalog.partitions {
            groups
                .entry((p.table_schema.as_str(), p.table_name.as_str()))
                .or_default()
                .push(p);
        }
        for ((database, table), parts) in groups {
            let key = ObjectKey::in_database(database, Kind::Table, table);
            let owner = self.id("a partition", &key)?;
            let show = self.table_show(&key)?;
            let first = parts[0];
            let mut names: Vec<&str> = Vec::new();
            for p in &parts {
                if !names.contains(&p.partition_name.as_str()) {
                    names.push(p.partition_name.as_str());
                }
            }
            let per_partition = parts
                .iter()
                .filter(|p| p.partition_name == first.partition_name && p.subpartition_name.is_some())
                .count();
            let sub_method = first.subpartition_method.clone();
            let count = |n: usize, what: &str| int32(i64::try_from(n).unwrap_or(i64::MAX), format!("{what} of {key}"));
            let pt: &mut Partitionings = &mut self.rows.partitionings;
            pt.id.push(owner);
            pt.design.push(self.design);
            pt.method.push(first.partition_method.clone());
            pt.expression.push(first.partition_expression.as_deref().and_then(some));
            pt.key_algorithm
                .push(show.key_algorithm.map(|k| int32(k, &key)).transpose()?);
            pt.partition_count.push(if show.partitions_listed {
                None
            } else {
                Some(count(names.len(), "partitions")?)
            });
            pt.sub_method.push(sub_method.clone());
            pt.sub_expression
                .push(first.subpartition_expression.as_deref().and_then(some));
            pt.sub_key_algorithm
                .push(show.sub_key_algorithm.map(|k| int32(k, &key)).transpose()?);
            pt.subpartition_count
                .push(if sub_method.is_some() && !show.subpartitions_listed {
                    Some(count(per_partition, "subpartitions")?)
                } else {
                    None
                });
            let mut ids: HashMap<&str, Uuid> = HashMap::new();
            for p in parts {
                let partition_id = match ids.get(p.partition_name.as_str()) {
                    Some(id) => *id,
                    None => {
                        let id = Uuid::now_v7();
                        ids.insert(p.partition_name.as_str(), id);
                        let own = show
                            .partition_options
                            .get(&p.partition_name)
                            .cloned()
                            .unwrap_or_default();
                        self.push_partition(
                            owner,
                            None,
                            (id, int32(p.partition_ordinal_position, &key)?, &p.partition_name),
                            partition_values(&p.partition_method, p.partition_description.as_deref()),
                            some(&p.partition_comment),
                            own,
                        );
                        id
                    }
                };
                if let (Some(name), Some(at)) = (&p.subpartition_name, p.subpartition_ordinal_position) {
                    let own = show.partition_options.get(name).cloned().unwrap_or_default();
                    self.push_partition(
                        owner,
                        Some(partition_id),
                        (Uuid::now_v7(), int32(at, &key)?, name),
                        None,
                        None,
                        own,
                    );
                }
            }
        }
        Ok(())
    }

    fn push_partition(
        &mut self,
        partitioning: Uuid,
        parent: Option<Uuid>,
        (id, position, name): (Uuid, i32, &str),
        values: Option<String>,
        comment: Option<String>,
        own: crate::show::PartitionShow,
    ) {
        let p: &mut Partitions = &mut self.rows.partitions;
        p.id.push(id);
        p.design.push(self.design);
        p.partitioning.push(partitioning);
        p.parent.push(parent);
        p.position.push(position);
        p.name.push(name.to_string());
        p.values.push(values);
        p.engine.push(own.engine);
        p.comment.push(comment);
        p.data_directory.push(own.data_directory);
        p.index_directory.push(own.index_directory);
        p.max_rows.push(own.max_rows);
        p.min_rows.push(own.min_rows);
        p.tablespace.push(own.tablespace);
    }

    // --- views, routines, triggers, events, libraries --------------------------------------------------------------------------------

    fn programs(&mut self) -> Result<(), EngineError> {
        let catalog = &self.snap.catalog;
        for v in &catalog.views {
            let key = ObjectKey::in_database(&v.table_schema, Kind::View, &v.table_name);
            let id = self.id("a view", &key)?;
            let show = self
                .snap
                .shows
                .views
                .get(&key)
                .ok_or_else(|| missing("the import", format!("SHOW CREATE VIEW of {key}")))?;
            if show.duality {
                return Err(EngineError::Unsupported(format!(
                    "the view {key} is a JSON duality view, which an import refuses: a later task reads it"
                )));
            }
            let o: &mut Views = &mut self.rows.views;
            o.id.push(id);
            o.design.push(self.design);
            o.definition.push(show.definition.clone());
            o.algorithm.push(show.algorithm.clone());
            o.definer.push(definer(&v.definer));
            o.security.push(v.security_type.clone());
            o.check_option
                .push((v.check_option != "NONE").then(|| v.check_option.clone()));
            o.character_set_client.push(v.character_set_client.clone());
            o.collation_connection.push(v.collation_connection.clone());
        }
        let mut routine_ids: HashMap<(&str, &str, &str), (Uuid, Kind)> = HashMap::new();
        for r in &catalog.routines {
            let kind = routine_kind(&r.routine_type)?;
            let key = ObjectKey::in_database(&r.routine_schema, kind, &r.routine_name);
            let id = self.id("a routine", &key)?;
            routine_ids.insert(
                (
                    r.routine_schema.as_str(),
                    r.routine_name.as_str(),
                    r.routine_type.as_str(),
                ),
                (id, kind),
            );
            let show = self
                .snap
                .shows
                .routines
                .get(&key)
                .ok_or_else(|| missing("the import", format!("SHOW CREATE of {key}")))?;
            let o: &mut Routines = &mut self.rows.routines;
            o.id.push(id);
            o.design.push(self.design);
            o.parameter_list.push(show.parameter_list.clone());
            o.returns.push(show.returns.clone());
            o.deterministic.push(r.is_deterministic);
            o.data_access.push(r.sql_data_access.clone());
            o.security.push(r.security_type.clone());
            o.definer.push(definer(&r.definer));
            o.language
                .push(r.external_language.clone().unwrap_or_else(|| "SQL".to_string()));
            o.body.push(show.body.clone());
            o.sql_mode.push(r.sql_mode.clone());
            o.character_set_client.push(r.character_set_client.clone());
            o.collation_connection.push(r.collation_connection.clone());
            o.database_collation.push(r.database_collation.clone());
        }
        for p in &catalog.parameters {
            if p.ordinal_position == 0 {
                continue;
            }
            let (routine, kind) = routine_ids
                .get(&(
                    p.specific_schema.as_str(),
                    p.specific_name.as_str(),
                    p.routine_type.as_str(),
                ))
                .copied()
                .ok_or_else(|| {
                    missing(
                        format!("a parameter of {}.{}", p.specific_schema, p.specific_name),
                        "its routine",
                    )
                })?;
            let name = p.parameter_name.clone().ok_or_else(|| {
                missing(
                    format!("parameter {} of {}", p.ordinal_position, p.specific_name),
                    "a name",
                )
            })?;
            let o: &mut RoutineParameters = &mut self.rows.routine_parameters;
            o.id.push(Uuid::now_v7());
            o.design.push(self.design);
            o.routine.push(routine);
            o.position.push(int32(p.ordinal_position, &name)?);
            o.mode.push(if kind == Kind::Function {
                None
            } else {
                p.parameter_mode.clone()
            });
            o.name.push(name);
            o.r#type.push(p.dtd_identifier.clone());
        }
        for t in &catalog.triggers {
            let key = ObjectKey::in_database(&t.trigger_schema, Kind::Trigger, &t.trigger_name);
            let id = self.id("a trigger", &key)?;
            let o: &mut Triggers = &mut self.rows.triggers;
            o.id.push(id);
            o.design.push(self.design);
            o.timing.push(t.action_timing.clone());
            o.event.push(t.event_manipulation.clone());
            o.action_order.push(int32(t.action_order, &key)?);
            o.body.push(t.action_statement.clone());
            o.definer.push(definer(&t.definer));
            o.sql_mode.push(t.sql_mode.clone());
            o.character_set_client.push(t.character_set_client.clone());
            o.collation_connection.push(t.collation_connection.clone());
            o.database_collation.push(t.database_collation.clone());
        }
        for e in &catalog.events {
            let key = ObjectKey::in_database(&e.event_schema, Kind::Event, &e.event_name);
            let id = self.id("an event", &key)?;
            let status = match e.status.as_str() {
                "ENABLED" => "ENABLE",
                "DISABLED" => "DISABLE",
                "SLAVESIDE_DISABLED" => "DISABLE ON SLAVE",
                "REPLICA_SIDE_DISABLED" => "DISABLE ON REPLICA",
                other => return Err(missing(&key, format!("a status MySQL has, not `{other}`"))),
            };
            let o: &mut Events = &mut self.rows.events;
            o.id.push(id);
            o.design.push(self.design);
            o.execute_at.push(e.execute_at.clone());
            o.interval_value.push(e.interval_value.clone());
            o.interval_field.push(e.interval_field.clone());
            o.starts.push(e.starts.clone());
            o.ends.push(e.ends.clone());
            o.on_completion.push(e.on_completion.clone());
            o.status.push(status.to_string());
            o.body.push(e.event_definition.clone());
            o.definer.push(definer(&e.definer));
            o.time_zone.push(e.time_zone.clone());
            o.sql_mode.push(e.sql_mode.clone());
            o.character_set_client.push(e.character_set_client.clone());
            o.collation_connection.push(e.collation_connection.clone());
            o.database_collation.push(e.database_collation.clone());
        }
        for l in &catalog.libraries {
            let key = ObjectKey::in_database(&l.library_schema, Kind::Library, &l.library_name);
            let id = self.id("a library", &key)?;
            let o: &mut Libraries = &mut self.rows.libraries;
            o.id.push(id);
            o.design.push(self.design);
            o.language.push(l.language.clone());
            o.source.push(l.library_definition.clone());
            o.sql_mode.push(l.sql_mode.clone());
        }
        Ok(())
    }

    // --- accounts, roles and what they hold ------------------------------------------------------------------------------------------

    /// The id of an account or role, none for the server's own, an error for one the catalogs do not list.
    fn account(&self, what: impl Display, name: &AccountName) -> Result<Option<Uuid>, EngineError> {
        if is_system_account(&name.user) {
            return Ok(None);
        }
        self.accounts
            .get(name)
            .copied()
            .map(Some)
            .ok_or_else(|| missing(what, format!("the account {}", name.object_name())))
    }

    fn accounts_and_grants(&mut self) -> Result<(), EngineError> {
        let catalog = &self.snap.catalog;
        for a in &catalog.accounts {
            let name = AccountName::new(&a.user, &a.host);
            let show = &self.snap.shows.users[&name];
            let kind = self.account_kind(show);
            let id = self.id("an account", &ObjectKey::of_server(kind, &name.object_name()))?;
            self.accounts.insert(name.clone(), id);
            let what = name.object_name();
            let limit = |v: i64| int32(v, &what);
            let o: &mut Accounts = &mut self.rows.accounts;
            o.id.push(id);
            o.design.push(self.design);
            o.user_name.push(name.user.clone());
            o.host.push(name.host.clone());
            o.auth_plugin.push(show.auth_plugin.clone());
            o.auth_string.push(show.auth_string.clone());
            o.ssl_type.push(Some(show.ssl_type.clone()));
            o.ssl_cipher.push(show.ssl_cipher.clone());
            o.x509_issuer.push(show.x509_issuer.clone());
            o.x509_subject.push(show.x509_subject.clone());
            o.max_queries_per_hour.push(limit(show.max_queries_per_hour)?);
            o.max_updates_per_hour.push(limit(show.max_updates_per_hour)?);
            o.max_connections_per_hour.push(limit(show.max_connections_per_hour)?);
            o.max_user_connections.push(limit(show.max_user_connections)?);
            o.password_expire.push(show.password_expire.clone());
            o.password_history.push(show.password_history.clone());
            o.password_reuse_interval.push(show.password_reuse_interval.clone());
            o.password_require_current.push(show.password_require_current.clone());
            o.failed_login_attempts
                .push(show.failed_login_attempts.map(&limit).transpose()?);
            o.password_lock_time.push(show.password_lock_time.clone());
            o.locked.push(show.locked);
            o.attributes.push(show.attributes.clone());
        }
        for e in &catalog.role_edges {
            let role = AccountName::new(&e.from_user, &e.from_host);
            let grantee = AccountName::new(&e.to_user, &e.to_host);
            let (Some(role_id), Some(grantee_id)) = (
                self.account("a role grant", &role)?,
                self.account("a role grant", &grantee)?,
            ) else {
                continue;
            };
            let is_default = catalog.default_roles.iter().any(|d| {
                d.user == e.to_user
                    && d.host == e.to_host
                    && d.default_role_user == e.from_user
                    && d.default_role_host == e.from_host
            });
            let o: &mut RoleGrants = &mut self.rows.role_grants;
            o.id.push(Uuid::now_v7());
            o.design.push(self.design);
            o.grantee.push(grantee_id);
            o.role.push(role_id);
            o.admin_option.push(e.with_admin_option);
            o.is_default.push(is_default);
        }
        let levels: [(&str, &Vec<GrantRow>); 4] = [
            ("global", &catalog.user_privileges),
            ("database", &catalog.schema_privileges),
            ("table", &catalog.table_privileges),
            ("column", &catalog.column_privileges),
        ];
        for (level, grants) in levels {
            for g in grants {
                if g.privilege_type == "USAGE" {
                    continue;
                }
                let (user, host) = split_grantee(&g.grantee).ok_or_else(|| {
                    missing(
                        "a privilege",
                        format!("a grantee MySQL writes as 'user'@'host', not {}", g.grantee),
                    )
                })?;
                let grantee = AccountName::new(&user, &host);
                let Some(grantee_id) = self.account(format!("a {level} privilege"), &grantee)? else {
                    continue;
                };
                let object = match (level, &g.table_schema, &g.table_name) {
                    ("table" | "column", Some(d), Some(t)) => self.table_or_view(d, t).map(|(id, _)| id),
                    _ => None,
                };
                self.push_privilege(
                    grantee_id,
                    &g.privilege_type,
                    level,
                    (g.table_schema.clone(), object, g.table_name.clone()),
                    (None, g.column_name.clone(), None),
                    g.is_grantable,
                );
            }
        }
        for r in &catalog.routine_privileges {
            let grantee = AccountName::new(&r.user, &r.host);
            let Some(grantee_id) = self.account("a routine privilege", &grantee)? else {
                continue;
            };
            let kind = routine_kind(&r.routine_type)?;
            let object = self
                .objects
                .get(&ObjectKey::in_database(&r.db, kind, &r.routine_name))
                .copied();
            let granted: Vec<&str> = r
                .proc_priv
                .split(',')
                .map(str::trim)
                .filter(|p| !p.is_empty())
                .collect();
            let grant_option = granted.iter().any(|p| p.eq_ignore_ascii_case("Grant"));
            for privilege in granted.into_iter().filter(|p| !p.eq_ignore_ascii_case("Grant")) {
                self.push_privilege(
                    grantee_id,
                    &privilege.to_uppercase(),
                    "routine",
                    (Some(r.db.clone()), object, Some(r.routine_name.clone())),
                    (Some(r.routine_type.to_uppercase()), None, None),
                    grant_option,
                );
            }
        }
        for p in &catalog.proxy_privileges {
            let grantee = AccountName::new(&p.user, &p.host);
            let proxied = AccountName::new(&p.proxied_user, &p.proxied_host);
            let (Some(grantee_id), Some(proxied_id)) = (
                self.account("a proxy privilege", &grantee)?,
                self.account("a proxy privilege", &proxied)?,
            ) else {
                continue;
            };
            self.push_privilege(
                grantee_id,
                "PROXY",
                "proxy",
                (None, None, None),
                (None, None, Some(proxied_id)),
                p.with_grant,
            );
        }
        Ok(())
    }

    fn push_privilege(
        &mut self,
        grantee: Uuid,
        privilege: &str,
        level: &str,
        (database, object, object_name): (Option<String>, Option<Uuid>, Option<String>),
        (routine_kind, column_name, proxied): (Option<String>, Option<String>, Option<Uuid>),
        grant_option: bool,
    ) {
        let (database, object_name) = match level {
            "global" | "proxy" => (None, None),
            "database" => (database, None),
            _ => (database, object_name),
        };
        let p: &mut Privileges = &mut self.rows.privileges;
        p.id.push(Uuid::now_v7());
        p.design.push(self.design);
        p.grantee.push(grantee);
        p.privilege.push(privilege.to_string());
        p.level.push(level.to_string());
        p.database_name.push(database);
        p.object.push(object);
        p.object_name.push(object_name);
        p.routine_kind.push(routine_kind);
        p.column_name.push(column_name);
        p.proxied.push(proxied);
        p.grant_option.push(grant_option);
    }

    // --- the server's own objects ----------------------------------------------------------------------------------------------------

    fn server_objects(&mut self) -> Result<(), EngineError> {
        let catalog = &self.snap.catalog;
        for s in &catalog.servers {
            let id = self.id("a server", &ObjectKey::of_server(Kind::Server, &s.server_name))?;
            let o: &mut Servers = &mut self.rows.servers;
            o.id.push(id);
            o.design.push(self.design);
            o.wrapper.push(s.wrapper.clone());
            o.host.push(some(&s.host));
            o.port
                .push((s.port != 0).then(|| int32(s.port, &s.server_name)).transpose()?);
            o.socket.push(some(&s.socket));
            o.database_name.push(some(&s.db));
            o.user_name.push(some(&s.username));
            o.owner.push(some(&s.owner));
        }
        for f in &catalog.loadable_functions {
            let id = self.id(
                "a loadable function",
                &ObjectKey::of_server(Kind::LoadableFunction, &f.name),
            )?;
            let returns = match f.ret {
                0 => "STRING",
                1 => "REAL",
                2 => "INTEGER",
                4 => "DECIMAL",
                other => return Err(missing(&f.name, format!("a return type MySQL has, not {other}"))),
            };
            let o: &mut LoadableFunctions = &mut self.rows.loadable_functions;
            o.id.push(id);
            o.design.push(self.design);
            o.returns.push(returns.to_string());
            o.aggregate.push(f.kind == "aggregate");
            o.library.push(f.dl.clone());
        }
        for urn in &catalog.components {
            let id = self.id("a component", &ObjectKey::of_server(Kind::Component, urn))?;
            let o: &mut Components = &mut self.rows.components;
            o.id.push(id);
            o.design.push(self.design);
            o.urn.push(urn.clone());
        }
        for g in &catalog.resource_groups {
            let id = self.id(
                "a resource group",
                &ObjectKey::of_server(Kind::ResourceGroup, &g.resource_group_name),
            )?;
            let o: &mut ResourceGroups = &mut self.rows.resource_groups;
            o.id.push(id);
            o.design.push(self.design);
            o.r#type.push(g.resource_group_type.clone());
            o.enabled.push(g.resource_group_enabled);
            o.vcpus.push(g.vcpu_ids.as_deref().and_then(some));
            o.thread_priority
                .push(int32(g.thread_priority, &g.resource_group_name)?);
        }
        for s in &catalog.spatial_reference_systems {
            let id = self.id(
                "a spatial reference system",
                &ObjectKey::of_server(Kind::SpatialReferenceSystem, &s.srs_name),
            )?;
            let o: &mut SpatialReferenceSystems = &mut self.rows.spatial_reference_systems;
            o.id.push(id);
            o.design.push(self.design);
            o.srs_id.push(s.srs_id);
            o.definition.push(s.definition.clone());
            o.organization.push(s.organization.clone());
            o.organization_coordsys_id.push(s.organization_coordsys_id);
            o.description.push(s.description.as_deref().and_then(some));
        }
        for t in &catalog.tablespaces {
            let id = self.id("a tablespace", &ObjectKey::of_server(Kind::Tablespace, &t.name))?;
            let file_name = t
                .file_name
                .clone()
                .ok_or_else(|| missing(format!("the tablespace {}", t.name), "a file in FILES"))?;
            let o: &mut Tablespaces = &mut self.rows.tablespaces;
            o.id.push(id);
            o.design.push(self.design);
            o.engine.push("InnoDB".to_string());
            o.file_name.push(file_name);
            o.encryption.push(t.encryption.as_ref().map(|e| e == "Y"));
            o.autoextend_size
                .push(t.autoextend_size.filter(|s| *s != 0).map(|s| s.to_string()));
        }
        for d in &catalog.compression_dictionaries {
            let id = self.id(
                "a compression dictionary",
                &ObjectKey::of_server(Kind::CompressionDictionary, &d.name),
            )?;
            let o: &mut CompressionDictionaries = &mut self.rows.compression_dictionaries;
            o.id.push(id);
            o.design.push(self.design);
            o.data.push(d.data.clone());
        }
        Ok(())
    }
}

fn push_namespace(ns: &mut Namespaces, id: Uuid, design: Uuid, parent: Option<Uuid>, name: &str, place: i32) {
    ns.id.push(id);
    ns.design.push(design);
    ns.parent.push(parent);
    ns.name.push(name.to_string());
    ns.position.push(place);
    ns.comment.push(None);
}

fn routine_kind(routine_type: &str) -> Result<Kind, EngineError> {
    match routine_type {
        "PROCEDURE" => Ok(Kind::Procedure),
        "FUNCTION" => Ok(Kind::Function),
        other => Err(EngineError::Source(format!(
            "a routine of type `{other}`, which MySQL does not have"
        ))),
    }
}

/// A partition's `VALUES`: `LESS THAN (...)` or `LESS THAN MAXVALUE` for RANGE, `IN (...)` for LIST, none otherwise.
fn partition_values(method: &str, description: Option<&str>) -> Option<String> {
    let description = description?;
    if method.starts_with("RANGE") {
        Some(if description == "MAXVALUE" {
            "LESS THAN MAXVALUE".to_string()
        } else {
            format!("LESS THAN ({description})")
        })
    } else if method.starts_with("LIST") {
        Some(format!("IN ({description})"))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::{Catalog, ColumnRow, ForeignKeyColumn, Schemata, Statistic, TableRow};
    use crate::read::Identity;
    use crate::show::{IndexShow, TableShow};
    use schema_forge_engine::Probe;

    fn table(name: &str) -> TableRow {
        TableRow {
            table_schema: "shop".into(),
            table_name: name.into(),
            engine: Some("InnoDB".into()),
            table_collation: Some("utf8mb4_0900_ai_ci".into()),
            create_options: Some("row_format=DYNAMIC stats_persistent=1".into()),
            table_comment: String::new(),
        }
    }

    fn column(table: &str, name: &str, position: i64) -> ColumnRow {
        ColumnRow {
            table_schema: "shop".into(),
            table_name: table.into(),
            ordinal_position: position,
            column_name: name.into(),
            column_type: "int".into(),
            is_nullable: false,
            column_default: None,
            extra: String::new(),
            generation_expression: None,
            character_set_name: None,
            collation_name: None,
            column_comment: String::new(),
            srs_id: None,
        }
    }

    fn primary(table: &str, column: &str) -> Statistic {
        Statistic {
            table_schema: "shop".into(),
            table_name: table.into(),
            index_name: "PRIMARY".into(),
            non_unique: false,
            seq_in_index: 1,
            column_name: Some(column.into()),
            sub_part: None,
            collation: Some("A".into()),
            index_type: "BTREE".into(),
            index_comment: String::new(),
            expression: None,
            is_visible: Some("YES".into()),
        }
    }

    fn foreign_key(to_table: &str) -> ForeignKeyColumn {
        ForeignKeyColumn {
            table_schema: "shop".into(),
            table_name: "orders".into(),
            constraint_name: "fk_customer".into(),
            column_name: "customer_id".into(),
            ordinal_position: 1,
            referenced_table_schema: "shop".into(),
            referenced_table_name: to_table.into(),
            referenced_column_name: "id".into(),
            update_rule: "RESTRICT".into(),
            delete_rule: "CASCADE".into(),
        }
    }

    /// A database `shop` with `customers` and `orders`, `orders` keyed to `to_table`.
    fn snapshot(to_table: &str) -> Snapshot {
        let mut catalog = Catalog::default();
        catalog.schemata.push(Schemata {
            schema_name: "shop".into(),
            default_character_set_name: "utf8mb4".into(),
            default_collation_name: "utf8mb4_0900_ai_ci".into(),
            default_encryption: Some("NO".into()),
        });
        catalog.tables = vec![table("customers"), table("orders")];
        catalog.columns = vec![
            column("customers", "id", 1),
            column("orders", "id", 1),
            column("orders", "customer_id", 2),
        ];
        catalog.statistics = vec![primary("customers", "id"), primary("orders", "id")];
        catalog.foreign_keys = vec![foreign_key(to_table)];
        let mut snapshot = Snapshot {
            identity: Identity {
                full: "8.0.46".into(),
                probe: Probe {
                    version: "8.0".into(),
                    flavor: "mysql".into(),
                },
                character_set: "utf8mb4".into(),
                collation: "utf8mb4_0900_ai_ci".into(),
                lower_case_table_names: 0,
                sql_mode: String::new(),
            },
            catalog,
            shows: crate::read::Shows::default(),
        };
        for name in ["customers", "orders"] {
            let mut show = TableShow::default();
            show.indexes.push(IndexShow {
                name: "PRIMARY".into(),
                ..IndexShow::default()
            });
            if name == "orders" {
                show.constraints.push("fk_customer".into());
            }
            snapshot
                .shows
                .tables
                .insert(ObjectKey::in_database("shop", Kind::Table, name), show);
        }
        snapshot
    }

    #[test]
    fn every_object_is_named_by_its_typed_key_and_given_one_id() {
        let rows = build(&snapshot("customers"), Uuid::now_v7()).unwrap();
        assert_eq!(rows.namespaces.len(), 2, "the server and its database");
        assert_eq!(rows.objects.len(), 2);
        assert_eq!(rows.tables.len(), 2);
        assert_eq!(rows.columns.len(), 3);
        // two primary keys and one foreign key, the foreign key pointing at the customers table's object
        let mut kinds = rows.constraints.kind.clone();
        kinds.sort();
        assert_eq!(kinds, ["foreign", "primary", "primary"]);
        let customers = rows.objects.name.iter().position(|n| n == "customers").unwrap();
        let foreign = rows.constraints.kind.iter().position(|k| k == "foreign").unwrap();
        assert_eq!(rows.constraints.to_object[foreign], Some(rows.objects.id[customers]));
        assert_eq!(rows.constraints.on_delete[foreign].as_deref(), Some("cascade"));
        assert_eq!(rows.objects.position, [1, 2]);
    }

    #[test]
    fn a_reference_to_nothing_in_the_catalogs_is_an_error_naming_it() {
        let error = build(&snapshot("missing_table"), Uuid::now_v7()).unwrap_err();
        let said = error.to_string();
        assert!(said.contains("fk_customer"), "{said}");
        assert!(said.contains("table shop.missing_table"), "{said}");
    }

    #[test]
    fn an_empty_string_for_none_is_stored_as_null() {
        assert_eq!(some(""), None);
        assert_eq!(some("who buys").as_deref(), Some("who buys"));
        let rows = build(&snapshot("customers"), Uuid::now_v7()).unwrap();
        assert!(rows.objects.comment.iter().all(Option::is_none));
    }

    #[test]
    fn the_options_of_a_table_are_read_where_they_are_written() {
        let options = create_options("row_format=DYNAMIC KEY_BLOCK_SIZE=8 compression=\"lz4\" partitioned");
        assert_eq!(options["row_format"], "DYNAMIC");
        assert_eq!(options["key_block_size"], "8");
        assert_eq!(options["compression"], "lz4");
        assert!(!options.contains_key("partitioned"));
        assert_eq!(
            partition_values("RANGE", Some("MAXVALUE")).as_deref(),
            Some("LESS THAN MAXVALUE")
        );
        assert_eq!(partition_values("LIST", Some("1,2")).as_deref(), Some("IN (1,2)"));
        assert_eq!(partition_values("HASH", None), None);
    }
}
