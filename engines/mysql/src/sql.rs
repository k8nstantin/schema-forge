//! From a design to SQL: the statements a MySQL server of the design's version loads, in a fixed order. Databases, the
//! server's own objects the tables need, tables (a MERGE table after the tables it unites), read-only databases, views in
//! dependency order, then, under `DELIMITER $sf_end$`, libraries, routines, triggers and events, then accounts, roles,
//! grants, and last the components. A value a statement needs and the design lacks is an error naming the object, never
//! written as a placeholder.

use std::collections::{HashMap, HashSet};

use schema_forge_engine::EngineError;
use uuid::Uuid;

use crate::keys::{lit, q};
use crate::load::{ById, Design};
use crate::rows::Rows;

/// The end of every statement of a program: a body holds semicolons, and a JavaScript body is quoted with `$$`.
const END: &str = "$sf_end$";

/// A value the design lacks, as an error naming the object.
fn lacks(object: &str, what: &str) -> EngineError {
    EngineError::Unsupported(format!("{object}: the design has no {what}, which its statement needs"))
}

/// The row of an id in a table's map, or an error naming what was looked for.
fn place(map: &ById, id: Uuid, object: &str, what: &str) -> Result<usize, EngineError> {
    map.get(&id).copied().ok_or_else(|| lacks(object, what))
}

/// The SQL of a design.
pub fn write(design: &Design) -> Result<String, EngineError> {
    let mut w = Writer {
        d: design,
        r: &design.rows,
        out: String::new(),
        end: ";",
    };
    w.all()?;
    Ok(w.out)
}

struct Writer<'a> {
    d: &'a Design,
    r: &'a Rows,
    out: String,
    /// What ends a statement: `;`, or `$sf_end$` inside the programs.
    end: &'static str,
}

/// A privilege group: what is granted on one target to one grantee.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct Target<'a> {
    grantee: Uuid,
    level: &'a str,
    database: Option<&'a str>,
    object: Option<&'a str>,
    routine_kind: Option<&'a str>,
    proxied: Option<Uuid>,
    grant_option: bool,
}

impl<'a> Writer<'a> {
    fn line(&mut self, text: &str) {
        self.out.push_str(text);
        self.out.push('\n');
    }

    /// One statement, ended as the section ends them.
    fn statement(&mut self, text: &str) {
        self.out.push_str(text);
        self.out.push_str(self.end);
        self.out.push('\n');
    }

    // --- names ---------------------------------------------------------------------------------------------------------------

    fn namespace_name(&self, id: Uuid) -> &'a str {
        self.d
            .maps
            .namespace
            .get(&id)
            .map_or("", |&p| self.r.namespaces.name[p].as_str())
    }

    fn database_of(&self, object: usize) -> &'a str {
        self.namespace_name(self.r.objects.namespace[object])
    }

    fn name_of(&self, object: usize) -> &'a str {
        self.r.objects.name[object].as_str()
    }

    /// What an object is called in a message: `kind db.name`.
    fn called(&self, object: usize) -> String {
        format!(
            "the {} {}.{}",
            self.r.objects.kind[object],
            self.database_of(object),
            self.name_of(object)
        )
    }

    fn qualified(&self, object: usize) -> String {
        format!("{}.{}", q(self.database_of(object)), q(self.name_of(object)))
    }

    /// The objects of a kind, in the order the design gives them: each namespace in its position, each object in its.
    fn of_kind(&self, kind: &str) -> Vec<usize> {
        let mut found: Vec<usize> = (0..self.r.objects.id.len())
            .filter(|&o| self.r.objects.kind[o] == kind)
            .collect();
        found.sort_by_key(|&o| (self.namespace_position(o), self.r.objects.position[o], o));
        found
    }

    fn namespace_position(&self, object: usize) -> i32 {
        self.d
            .maps
            .namespace
            .get(&self.r.objects.namespace[object])
            .map_or(0, |&p| self.r.namespaces.position[p])
    }

    /// An account or role as MySQL writes it: `'user'@'host'`.
    fn account(&self, id: Uuid) -> Result<String, EngineError> {
        let row = place(&self.d.maps.account, id, "a grant", "account or role")?;
        let a = &self.r.accounts;
        Ok(format!("{}@{}", lit(&a.user_name[row]), lit(&a.host[row])))
    }

    // --- the whole ------------------------------------------------------------------------------------------------------------

    fn all(&mut self) -> Result<(), EngineError> {
        self.line("SET NAMES utf8mb4;");
        self.line("SET FOREIGN_KEY_CHECKS = 0;");
        self.line("SET UNIQUE_CHECKS = 0;");
        self.line("SET sql_mode = 'NO_ENGINE_SUBSTITUTION';");
        self.databases()?;
        self.server_objects()?;
        self.tables()?;
        self.read_only_databases()?;
        self.line("SET FOREIGN_KEY_CHECKS = 1;");
        self.views()?;
        self.programs()?;
        self.accounts()?;
        self.role_grants()?;
        self.privileges()?;
        self.components()?;
        Ok(())
    }

    // --- databases and the server's own objects --------------------------------------------------------------------------------

    /// The namespaces that are databases, in position order.
    fn database_namespaces(&self) -> Vec<usize> {
        let mut found: Vec<usize> = (0..self.r.namespaces.id.len())
            .filter(|&n| self.r.namespaces.parent[n].is_some())
            .collect();
        found.sort_by_key(|&n| (self.r.namespaces.position[n], n));
        found
    }

    fn databases(&mut self) -> Result<(), EngineError> {
        for n in self.database_namespaces() {
            let name = self.r.namespaces.name[n].as_str();
            let row = place(
                &self.d.maps.database,
                self.r.namespaces.id[n],
                &format!("the database {name}"),
                "character set and collation",
            )?;
            let t = &self.r.databases;
            let mut s = format!(
                "CREATE DATABASE {} DEFAULT CHARACTER SET {} COLLATE {}",
                q(name),
                t.character_set[row],
                t.collation[row]
            );
            if let Some(encrypted) = t.encryption[row] {
                s.push_str(if encrypted {
                    " DEFAULT ENCRYPTION = 'Y'"
                } else {
                    " DEFAULT ENCRYPTION = 'N'"
                });
            }
            self.statement(&s);
        }
        Ok(())
    }

    fn read_only_databases(&mut self) -> Result<(), EngineError> {
        for n in self.database_namespaces() {
            let Some(&row) = self.d.maps.database.get(&self.r.namespaces.id[n]) else {
                continue;
            };
            if self.r.databases.read_only[row] == Some(true) {
                let s = format!("ALTER DATABASE {} READ ONLY = 1", q(&self.r.namespaces.name[n]));
                self.statement(&s);
            }
        }
        Ok(())
    }

    /// The engine row of a server object, by the object's id, or an error naming the object.
    fn engine_row(&self, map: &ById, object: usize, what: &str) -> Result<usize, EngineError> {
        place(map, self.r.objects.id[object], &self.called(object), what)
    }

    fn server_objects(&mut self) -> Result<(), EngineError> {
        for o in self.of_kind("tablespace") {
            let row = self.engine_row(&self.d.maps.tablespace, o, "tablespace row")?;
            let t = &self.r.tablespaces;
            let mut s = format!(
                "CREATE TABLESPACE {} ADD DATAFILE {}",
                q(self.name_of(o)),
                lit(t.file_name[row].trim_start_matches("./"))
            );
            if let Some(size) = &t.autoextend_size[row] {
                s.push_str(&format!(" AUTOEXTEND_SIZE = {size}"));
            }
            if let Some(encrypted) = t.encryption[row] {
                s.push_str(if encrypted {
                    " ENCRYPTION = 'Y'"
                } else {
                    " ENCRYPTION = 'N'"
                });
            }
            s.push_str(&format!(" ENGINE = {}", t.engine[row]));
            self.statement(&s);
        }
        for o in self.of_kind("spatial_reference_system") {
            let row = self.engine_row(&self.d.maps.spatial_reference_system, o, "spatial reference system row")?;
            let t = &self.r.spatial_reference_systems;
            let mut s = format!(
                "CREATE SPATIAL REFERENCE SYSTEM {} NAME {}",
                t.srs_id[row],
                lit(self.name_of(o))
            );
            if let Some(organization) = &t.organization[row] {
                let coordsys = t.organization_coordsys_id[row]
                    .ok_or_else(|| lacks(&self.called(o), "organization's coordinate system id"))?;
                s.push_str(&format!(" ORGANIZATION {} IDENTIFIED BY {coordsys}", lit(organization)));
            }
            s.push_str(&format!(" DEFINITION {}", lit(&t.definition[row])));
            if let Some(description) = &t.description[row] {
                s.push_str(&format!(" DESCRIPTION {}", lit(description)));
            }
            self.statement(&s);
        }
        for o in self.of_kind("compression_dictionary") {
            let row = self.engine_row(&self.d.maps.compression_dictionary, o, "dictionary row")?;
            let s = format!(
                "CREATE COMPRESSION_DICTIONARY {} ({})",
                q(self.name_of(o)),
                lit(&self.r.compression_dictionaries.data[row])
            );
            self.statement(&s);
        }
        for o in self.of_kind("server") {
            let row = self.engine_row(&self.d.maps.server, o, "server row")?;
            let t = &self.r.servers;
            let mut options: Vec<String> = Vec::new();
            let text = |name: &str, value: &Option<String>, into: &mut Vec<String>| {
                if let Some(v) = value {
                    into.push(format!("{name} {}", lit(v)));
                }
            };
            text("HOST", &t.host[row], &mut options);
            text("DATABASE", &t.database_name[row], &mut options);
            text("USER", &t.user_name[row], &mut options);
            text("SOCKET", &t.socket[row], &mut options);
            text("OWNER", &t.owner[row], &mut options);
            if let Some(port) = t.port[row] {
                options.push(format!("PORT {port}"));
            }
            if options.is_empty() {
                return Err(lacks(
                    &self.called(o),
                    "option (host, database, user, socket, owner or port)",
                ));
            }
            let s = format!(
                "CREATE SERVER {} FOREIGN DATA WRAPPER {} OPTIONS ({})",
                q(self.name_of(o)),
                t.wrapper[row],
                options.join(", ")
            );
            self.statement(&s);
        }
        for o in self.of_kind("loadable_function") {
            let row = self.engine_row(&self.d.maps.loadable_function, o, "function row")?;
            let t = &self.r.loadable_functions;
            let s = format!(
                "CREATE {}FUNCTION {} RETURNS {} SONAME {}",
                if t.aggregate[row] { "AGGREGATE " } else { "" },
                q(self.name_of(o)),
                t.returns[row],
                lit(&t.library[row])
            );
            self.statement(&s);
        }
        for o in self.of_kind("resource_group") {
            let row = self.engine_row(&self.d.maps.resource_group, o, "resource group row")?;
            let t = &self.r.resource_groups;
            let mut s = format!("CREATE RESOURCE GROUP {} TYPE = {}", q(self.name_of(o)), t.r#type[row]);
            if let Some(vcpus) = &t.vcpus[row] {
                s.push_str(&format!(" VCPU = {vcpus}"));
            }
            s.push_str(&format!(" THREAD_PRIORITY = {}", t.thread_priority[row]));
            s.push_str(if t.enabled[row] { " ENABLE" } else { " DISABLE" });
            self.statement(&s);
        }
        Ok(())
    }

    // --- tables -----------------------------------------------------------------------------------------------------------------

    fn tables(&mut self) -> Result<(), EngineError> {
        let all = self.of_kind("table");
        let mut plain = Vec::new();
        let mut merged = Vec::new();
        for o in all {
            let row = self.engine_row(&self.d.maps.table, o, "table options")?;
            if self.r.tables.engine[row].eq_ignore_ascii_case("MRG_MYISAM")
                || self.r.tables.engine[row].eq_ignore_ascii_case("MERGE")
            {
                merged.push(o);
            } else {
                plain.push(o);
            }
        }
        for o in plain.into_iter().chain(merged) {
            let use_database = format!("USE {}", q(self.database_of(o)));
            self.statement(&use_database);
            let create = self.table(o)?;
            self.statement(&create);
        }
        Ok(())
    }

    fn table(&self, o: usize) -> Result<String, EngineError> {
        let object = self.r.objects.id[o];
        let called = self.called(o);
        let mut lines: Vec<String> = Vec::new();
        for &c in self.d.maps.columns_of.get(&object).map_or(&[][..], Vec::as_slice) {
            lines.push(self.column(c, &called)?);
        }
        for &i in self.d.maps.indexes_of.get(&object).map_or(&[][..], Vec::as_slice) {
            lines.push(self.index(i, &called)?);
        }
        for &k in self.d.maps.constraints_of.get(&object).map_or(&[][..], Vec::as_slice) {
            if let Some(line) = self.constraint(k, &called)? {
                lines.push(line);
            }
        }
        let mut s = format!("CREATE TABLE {} (\n  {}\n)", q(self.name_of(o)), lines.join(",\n  "));
        s.push_str(&self.table_options(o)?);
        s.push_str(&self.partitioning(o, &called)?);
        Ok(s)
    }

    fn column(&self, c: usize, table: &str) -> Result<String, EngineError> {
        let t = &self.r.columns;
        let name = &t.name[c];
        let called = format!("the column {name} of {table}");
        let at = place(&self.d.maps.column_options, t.id[c], &called, "engine options")?;
        let o = &self.r.column_options;
        let mut s = format!("{} {}", q(name), t.r#type[c]);
        if let Some(collation) = &t.collation[c] {
            if let Some(character_set) = &o.character_set[at] {
                s.push_str(&format!(" CHARACTER SET {character_set}"));
            }
            s.push_str(&format!(" COLLATE {collation}"));
        }
        let nullability = if t.nullable[c] { " NULL" } else { " NOT NULL" };
        if let Some(expression) = &t.generated_expression[c] {
            s.push_str(&format!(" GENERATED ALWAYS AS ({expression})"));
            s.push_str(if t.generated_stored[c] == Some(true) {
                " STORED"
            } else {
                " VIRTUAL"
            });
            s.push_str(nullability);
        } else {
            s.push_str(nullability);
            if let Some(default) = &t.default_value[c] {
                let upper = default.to_uppercase();
                let timestamp = upper.starts_with("CURRENT_TIMESTAMP") || upper.starts_with("NOW(");
                if o.default_is_expression[at] {
                    if timestamp {
                        s.push_str(&format!(" DEFAULT {default}"));
                    } else {
                        s.push_str(&format!(" DEFAULT ({default})"));
                    }
                } else if t.r#type[c].to_lowercase().starts_with("bit") && default.starts_with("b'") {
                    s.push_str(&format!(" DEFAULT {default}"));
                } else {
                    s.push_str(&format!(" DEFAULT {}", lit(default)));
                }
            }
        }
        if o.invisible[at] {
            s.push_str(" INVISIBLE");
        }
        if o.auto_increment[at] {
            s.push_str(" AUTO_INCREMENT");
        }
        if let Some(on_update) = &o.on_update[at] {
            s.push_str(&format!(" ON UPDATE {on_update}"));
        }
        if let Some(comment) = &t.comment[c] {
            s.push_str(&format!(" COMMENT {}", lit(comment)));
        }
        if let Some(format) = &o.column_format[at] {
            s.push_str(&format!(" COLUMN_FORMAT {format}"));
            if let Some(dictionary) = o.compression_dictionary[at] {
                let d = place(&self.d.maps.object, dictionary, &called, "compression dictionary")?;
                s.push_str(&format!(" WITH COMPRESSION_DICTIONARY {}", q(self.name_of(d))));
            }
        }
        if let Some(engine_attribute) = &o.engine_attribute[at] {
            s.push_str(&format!(" ENGINE_ATTRIBUTE {}", lit(engine_attribute)));
        }
        if let Some(secondary) = &o.secondary_engine_attribute[at] {
            s.push_str(&format!(" SECONDARY_ENGINE_ATTRIBUTE {}", lit(secondary)));
        }
        if let Some(storage) = &o.storage[at] {
            s.push_str(&format!(" STORAGE {storage}"));
        }
        if let Some(srid) = o.srid[at] {
            s.push_str(&format!(" SRID {srid}"));
        }
        Ok(s)
    }

    fn column_name(&self, id: Uuid, what: &str) -> Result<&'a str, EngineError> {
        let c = place(&self.d.maps.column, id, what, "column")?;
        Ok(self.r.columns.name[c].as_str())
    }

    fn index(&self, i: usize, table: &str) -> Result<String, EngineError> {
        let t = &self.r.indexes;
        let name = &t.name[i];
        let called = format!("the index {name} of {table}");
        let at = place(&self.d.maps.index_options, t.id[i], &called, "engine options")?;
        let o = &self.r.index_options;
        let mut parts: Vec<String> = Vec::new();
        for &p in self.d.maps.parts_of.get(&t.id[i]).map_or(&[][..], Vec::as_slice) {
            let part = &self.r.index_parts;
            let mut text = match (part.column[p], &part.expression[p]) {
                (Some(column), _) => q(self.column_name(column, &called)?),
                (None, Some(expression)) => format!("({expression})"),
                (None, None) => return Err(lacks(&called, "column or expression for a part")),
            };
            if let Some(&prefix) = self.d.maps.index_part_options.get(&part.id[p]) {
                text.push_str(&format!("({})", self.r.index_part_options.prefix_length[prefix]));
            }
            if part.descending[p] {
                text.push_str(" DESC");
            }
            parts.push(text);
        }
        let head = match o.kind[at].as_str() {
            "fulltext" => format!("FULLTEXT KEY {}", q(name)),
            "spatial" => format!("SPATIAL KEY {}", q(name)),
            _ if t.unique[i] && name == "PRIMARY" => "PRIMARY KEY".to_string(),
            _ if t.unique[i] => format!("UNIQUE KEY {}", q(name)),
            _ => format!("KEY {}", q(name)),
        };
        let mut s = format!("{head} ({})", parts.join(","));
        if let Some(method) = &t.method[i] {
            s.push_str(&format!(" USING {method}"));
        }
        if let Some(size) = o.key_block_size[at] {
            s.push_str(&format!(" KEY_BLOCK_SIZE={size}"));
        }
        if let Some(parser) = &o.parser[at] {
            s.push_str(&format!(" /*!50100 WITH PARSER {} */", q(parser)));
        }
        if let Some(comment) = &t.comment[i] {
            s.push_str(&format!(" COMMENT {}", lit(comment)));
        }
        if o.invisible[at] {
            s.push_str(" INVISIBLE");
        }
        if let Some(a) = &o.engine_attribute[at] {
            s.push_str(&format!(" ENGINE_ATTRIBUTE {}", lit(a)));
        }
        if let Some(a) = &o.secondary_engine_attribute[at] {
            s.push_str(&format!(" SECONDARY_ENGINE_ATTRIBUTE {}", lit(a)));
        }
        Ok(s)
    }

    /// A foreign or check key as a table's clause; primary and unique keys are their indexes.
    fn constraint(&self, k: usize, table: &str) -> Result<Option<String>, EngineError> {
        let t = &self.r.constraints;
        let kind = t.kind[k].as_str();
        if kind != "foreign" && kind != "check" {
            return Ok(None);
        }
        let called = format!(
            "the {kind} key {} of {table}",
            t.name[k].as_deref().unwrap_or("(unnamed)")
        );
        let named = t.name[k]
            .as_ref()
            .map_or(String::new(), |n| format!("CONSTRAINT {} ", q(n)));
        if kind == "check" {
            let expression = t.expression[k].as_ref().ok_or_else(|| lacks(&called, "expression"))?;
            let enforced = if t.enforced[k] { "" } else { " /*!80016 NOT ENFORCED */" };
            return Ok(Some(format!("{named}CHECK ({expression}){enforced}")));
        }
        let target = t.to_object[k].ok_or_else(|| lacks(&called, "referenced table"))?;
        let target = place(&self.d.maps.object, target, &called, "referenced table")?;
        let (mut from, mut to) = (Vec::new(), Vec::new());
        for &c in self
            .d
            .maps
            .constraint_columns_of
            .get(&t.id[k])
            .map_or(&[][..], Vec::as_slice)
        {
            let cc = &self.r.constraint_columns;
            from.push(q(self.column_name(cc.column[c], &called)?));
            let referenced = cc.to_column[c].ok_or_else(|| lacks(&called, "referenced column"))?;
            to.push(q(self.column_name(referenced, &called)?));
        }
        let mut s = format!(
            "{named}FOREIGN KEY ({}) REFERENCES {} ({})",
            from.join(","),
            self.qualified(target),
            to.join(",")
        );
        for (clause, rule) in [("ON DELETE", &t.on_delete[k]), ("ON UPDATE", &t.on_update[k])] {
            // A rule is never written as NO ACTION, which is what an unwritten rule reads back as on 8.0.
            let word = match rule.as_deref() {
                Some("cascade") => Some("CASCADE"),
                Some("set_null") => Some("SET NULL"),
                Some("set_default") => Some("SET DEFAULT"),
                Some("restrict") => Some("RESTRICT"),
                _ => None,
            };
            if let Some(word) = word {
                s.push_str(&format!(" {clause} {word}"));
            }
        }
        Ok(Some(s))
    }

    fn table_options(&self, o: usize) -> Result<String, EngineError> {
        let at = self.engine_row(&self.d.maps.table, o, "table options")?;
        let t = &self.r.tables;
        let mut s = format!(" ENGINE={}", t.engine[at]);
        s.push_str(&format!(" DEFAULT COLLATE={}", t.collation[at]));
        let number = |name: &str, value: Option<i64>, into: &mut String| {
            if let Some(v) = value {
                into.push_str(&format!(" {name}={v}"));
            }
        };
        let word = |name: &str, value: &Option<String>, into: &mut String| {
            if let Some(v) = value {
                into.push_str(&format!(" {name}={v}"));
            }
        };
        let text = |name: &str, value: &Option<String>, into: &mut String| {
            if let Some(v) = value {
                into.push_str(&format!(" {name}={}", lit(v)));
            }
        };
        number("AUTO_INCREMENT", t.auto_increment[at], &mut s);
        number("AVG_ROW_LENGTH", t.avg_row_length[at], &mut s);
        if let Some(checksum) = t.checksum[at] {
            s.push_str(&format!(" CHECKSUM={}", u8::from(checksum)));
        }
        text("COMPRESSION", &t.compression[at], &mut s);
        if let Some(delay) = t.delay_key_write[at] {
            s.push_str(&format!(" DELAY_KEY_WRITE={}", u8::from(delay)));
        }
        if let Some(encrypted) = t.encryption[at] {
            s.push_str(if encrypted {
                " ENCRYPTION='Y'"
            } else {
                " ENCRYPTION='N'"
            });
        }
        word("INSERT_METHOD", &t.insert_method[at], &mut s);
        if let Some(size) = t.key_block_size[at] {
            s.push_str(&format!(" KEY_BLOCK_SIZE={size}"));
        }
        number("MAX_ROWS", t.max_rows[at], &mut s);
        number("MIN_ROWS", t.min_rows[at], &mut s);
        word("PACK_KEYS", &t.pack_keys[at], &mut s);
        word("ROW_FORMAT", &t.row_format[at], &mut s);
        word("STATS_AUTO_RECALC", &t.stats_auto_recalc[at], &mut s);
        word("STATS_PERSISTENT", &t.stats_persistent[at], &mut s);
        word("STATS_SAMPLE_PAGES", &t.stats_sample_pages[at], &mut s);
        word("AUTOEXTEND_SIZE", &t.autoextend_size[at], &mut s);
        if let Some(tablespace) = &t.tablespace[at] {
            s.push_str(&format!(" TABLESPACE {}", q(tablespace)));
            if let Some(storage) = &t.storage[at] {
                s.push_str(&format!(" STORAGE {storage}"));
            }
        } else if let Some(storage) = &t.storage[at] {
            s.push_str(&format!(" /*!50100 STORAGE {storage} */"));
        }
        text("DATA DIRECTORY", &t.data_directory[at], &mut s);
        text("INDEX DIRECTORY", &t.index_directory[at], &mut s);
        let united = self.united(o)?;
        if !united.is_empty() {
            s.push_str(&format!(" UNION=({})", united.join(",")));
        }
        text("CONNECTION", &t.connection[at], &mut s);
        text("ENGINE_ATTRIBUTE", &t.engine_attribute[at], &mut s);
        word("SECONDARY_ENGINE", &t.secondary_engine[at], &mut s);
        text("SECONDARY_ENGINE_ATTRIBUTE", &t.secondary_engine_attribute[at], &mut s);
        if let Some(comment) = &self.r.objects.comment[o] {
            s.push_str(&format!(" COMMENT={}", lit(comment)));
        }
        Ok(s)
    }

    /// The tables a MERGE table unites, in order, named as its statement names them: without the database of its own.
    fn united(&self, o: usize) -> Result<Vec<String>, EngineError> {
        let d = &self.r.dependencies;
        let mut names = Vec::new();
        for &p in self
            .d
            .maps
            .dependencies_of
            .get(&self.r.objects.id[o])
            .map_or(&[][..], Vec::as_slice)
        {
            if d.r#as[p] != "union" {
                continue;
            }
            let target = place(&self.d.maps.object, d.uses[p], &self.called(o), "united table")?;
            names.push(if self.database_of(target) == self.database_of(o) {
                q(self.name_of(target))
            } else {
                self.qualified(target)
            });
        }
        Ok(names)
    }

    // --- partitioning -----------------------------------------------------------------------------------------------------------

    fn partitioning(&self, o: usize, called: &str) -> Result<String, EngineError> {
        let Some(&at) = self.d.maps.partitioning.get(&self.r.objects.id[o]) else {
            return Ok(String::new());
        };
        let t = &self.r.partitionings;
        let by = |method: &str, algorithm: Option<i32>, expression: &Option<String>| {
            let algorithm = algorithm.map_or(String::new(), |a| format!(" ALGORITHM = {a}"));
            let expression = expression.as_deref().unwrap_or_default();
            if method.contains("KEY") {
                format!("{method}{algorithm} ({expression})")
            } else {
                format!("{method} ({expression})")
            }
        };
        let mut s = format!(
            "\n/*!50100 PARTITION BY {}",
            by(&t.method[at], t.key_algorithm[at], &t.expression[at])
        );
        if let Some(sub) = &t.sub_method[at] {
            s.push_str(&format!(
                "\nSUBPARTITION BY {}",
                by(sub, t.sub_key_algorithm[at], &t.sub_expression[at])
            ));
        }
        let listed = self.d.maps.partitions_of.get(&t.id[at]).map_or(&[][..], Vec::as_slice);
        if let Some(count) = t.partition_count[at] {
            s.push_str(&format!("\nPARTITIONS {count}"));
        }
        // Subpartitions counted rather than listed are counted whether or not the partitions are listed.
        if let Some(sub) = t.subpartition_count[at] {
            s.push_str(&format!("\nSUBPARTITIONS {sub}"));
        }
        if t.partition_count[at].is_none() {
            let p = &self.r.partitions;
            let mut subs: HashMap<Uuid, Vec<usize>> = HashMap::new();
            for &i in listed {
                if let Some(parent) = p.parent[i] {
                    subs.entry(parent).or_default().push(i);
                }
            }
            let mut each = Vec::new();
            for &i in listed.iter().filter(|&&i| p.parent[i].is_none()) {
                let mut text = format!("PARTITION {}", q(&p.name[i]));
                if let Some(values) = &p.values[i] {
                    text.push_str(&format!(" VALUES {values}"));
                }
                text.push_str(&self.partition_options(i));
                if t.subpartition_count[at].is_none() && t.sub_method[at].is_some() {
                    let own = subs.get(&p.id[i]).map_or(&[][..], Vec::as_slice);
                    if own.is_empty() {
                        return Err(lacks(called, &format!("subpartitions of the partition {}", p.name[i])));
                    }
                    let own: Vec<String> = own
                        .iter()
                        .map(|&j| format!("SUBPARTITION {}{}", q(&p.name[j]), self.partition_options(j)))
                        .collect();
                    text.push_str(&format!("\n ({})", own.join(",\n  ")));
                }
                each.push(text);
            }
            if each.is_empty() {
                return Err(lacks(called, "partitions"));
            }
            s.push_str(&format!("\n({})", each.join(",\n ")));
        }
        s.push_str(" */");
        Ok(s)
    }

    fn partition_options(&self, i: usize) -> String {
        let p = &self.r.partitions;
        let mut s = String::new();
        if let Some(engine) = &p.engine[i] {
            s.push_str(&format!(" ENGINE = {engine}"));
        }
        if let Some(comment) = &p.comment[i] {
            s.push_str(&format!(" COMMENT = {}", lit(comment)));
        }
        if let Some(d) = &p.data_directory[i] {
            s.push_str(&format!(" DATA DIRECTORY = {}", lit(d)));
        }
        if let Some(d) = &p.index_directory[i] {
            s.push_str(&format!(" INDEX DIRECTORY = {}", lit(d)));
        }
        if let Some(n) = p.max_rows[i] {
            s.push_str(&format!(" MAX_ROWS = {n}"));
        }
        if let Some(n) = p.min_rows[i] {
            s.push_str(&format!(" MIN_ROWS = {n}"));
        }
        if let Some(t) = &p.tablespace[i] {
            s.push_str(&format!(" TABLESPACE = {}", q(t)));
        }
        s
    }

    // --- views ------------------------------------------------------------------------------------------------------------------

    /// The views in an order each comes after the views it reads; a cycle is an error naming its views.
    fn views_in_order(&self) -> Result<Vec<usize>, EngineError> {
        let views = self.of_kind("view");
        let in_design: HashSet<usize> = views.iter().copied().collect();
        let mut done: HashSet<usize> = HashSet::new();
        let mut order = Vec::new();
        let mut walking: Vec<usize> = Vec::new();
        for &v in &views {
            self.visit(v, &in_design, &mut done, &mut walking, &mut order)?;
        }
        Ok(order)
    }

    fn visit(
        &self,
        v: usize,
        views: &HashSet<usize>,
        done: &mut HashSet<usize>,
        walking: &mut Vec<usize>,
        order: &mut Vec<usize>,
    ) -> Result<(), EngineError> {
        if done.contains(&v) {
            return Ok(());
        }
        if let Some(start) = walking.iter().position(|&w| w == v) {
            let names: Vec<String> = walking[start..].iter().map(|&w| self.qualified(w)).collect();
            return Err(EngineError::Unsupported(format!(
                "views that read each other in a cycle cannot be created: {}",
                names.join(", ")
            )));
        }
        walking.push(v);
        let d = &self.r.dependencies;
        for &p in self
            .d
            .maps
            .dependencies_of
            .get(&self.r.objects.id[v])
            .map_or(&[][..], Vec::as_slice)
        {
            if d.r#as[p] != "reads" {
                continue;
            }
            if let Some(&target) = self.d.maps.object.get(&d.uses[p]).filter(|t| views.contains(t)) {
                self.visit(target, views, done, walking, order)?;
            }
        }
        walking.pop();
        done.insert(v);
        order.push(v);
        Ok(())
    }

    fn views(&mut self) -> Result<(), EngineError> {
        for v in self.views_in_order()? {
            let at = self.engine_row(&self.d.maps.view, v, "view options")?;
            let t = &self.r.views;
            let use_database = format!("USE {}", q(self.database_of(v)));
            let mut s = format!(
                "CREATE ALGORITHM={} DEFINER={} SQL SECURITY {} VIEW {} AS {}",
                t.algorithm[at],
                t.definer[at],
                t.security[at],
                q(self.name_of(v)),
                t.definition[at]
            );
            if let Some(check) = &t.check_option[at] {
                s.push_str(&format!(" WITH {check} CHECK OPTION"));
            }
            let session = format!(
                "SET character_set_client = {}, collation_connection = {}",
                t.character_set_client[at], t.collation_connection[at]
            );
            self.statement(&use_database);
            self.statement(&session);
            self.statement(&s);
        }
        Ok(())
    }

    // --- libraries, routines, triggers and events ----------------------------------------------------------------------------------

    fn session(&mut self, sql_mode: &str, client: Option<(&str, &str)>) {
        let mut s = format!("SET sql_mode = {}", lit(sql_mode));
        if let Some((character_set, collation)) = client {
            s.push_str(&format!(
                ", character_set_client = {character_set}, collation_connection = {collation}"
            ));
        }
        self.statement(&s);
    }

    fn programs(&mut self) -> Result<(), EngineError> {
        let libraries = self.of_kind("library");
        let procedures = self.of_kind("procedure");
        let functions = self.of_kind("function");
        let triggers = self.triggers_in_order()?;
        let events = self.of_kind("event");
        if libraries.is_empty()
            && procedures.is_empty()
            && functions.is_empty()
            && triggers.is_empty()
            && events.is_empty()
        {
            return Ok(());
        }
        self.line(&format!("DELIMITER {END}"));
        self.end = END;
        for o in libraries {
            let at = self.engine_row(&self.d.maps.library, o, "library row")?;
            let t = &self.r.libraries;
            let use_database = format!("USE {}", q(self.database_of(o)));
            self.statement(&use_database);
            self.session(&t.sql_mode[at], None);
            let comment = self.r.objects.comment[o]
                .as_ref()
                .map_or(String::new(), |c| format!(" COMMENT {}", lit(c)));
            let s = format!(
                "CREATE LIBRARY {} LANGUAGE {}{comment} AS $${}$$",
                q(self.name_of(o)),
                t.language[at],
                t.source[at]
            );
            self.statement(&s);
        }
        for o in procedures.into_iter().chain(functions) {
            let s = self.routine(o)?;
            let use_database = format!("USE {}", q(self.database_of(o)));
            let at = self.engine_row(&self.d.maps.routine, o, "routine row")?;
            let t = &self.r.routines;
            self.statement(&use_database);
            self.session(
                &t.sql_mode[at],
                Some((&t.character_set_client[at], &t.collation_connection[at])),
            );
            self.statement(&s);
        }
        for (o, follows) in triggers {
            let s = self.trigger(o, follows)?;
            let use_database = format!("USE {}", q(self.database_of(o)));
            let at = self.engine_row(&self.d.maps.trigger, o, "trigger row")?;
            let t = &self.r.triggers;
            self.statement(&use_database);
            self.session(
                &t.sql_mode[at],
                Some((&t.character_set_client[at], &t.collation_connection[at])),
            );
            self.statement(&s);
        }
        for o in events {
            let at = self.engine_row(&self.d.maps.event, o, "event row")?;
            let t = &self.r.events;
            let use_database = format!("USE {}", q(self.database_of(o)));
            self.statement(&use_database);
            self.session(
                &t.sql_mode[at],
                Some((&t.character_set_client[at], &t.collation_connection[at])),
            );
            let zone = format!("SET time_zone = {}", lit(&t.time_zone[at]));
            self.statement(&zone);
            let s = self.event(o)?;
            self.statement(&s);
        }
        self.end = ";";
        self.line("DELIMITER ;");
        // The programs' own sessions end here: what follows (accounts, their hashes, grants) is read as the script began.
        self.line("SET NAMES utf8mb4;");
        self.line("SET sql_mode = 'NO_ENGINE_SUBSTITUTION';");
        Ok(())
    }

    fn routine(&self, o: usize) -> Result<String, EngineError> {
        let at = self.engine_row(&self.d.maps.routine, o, "routine row")?;
        let t = &self.r.routines;
        let function = self.r.objects.kind[o] == "function";
        let mut s = format!(
            "CREATE DEFINER={} {} {}({})",
            t.definer[at],
            if function { "FUNCTION" } else { "PROCEDURE" },
            q(self.name_of(o)),
            t.parameter_list[at]
        );
        if function {
            let returns = t.returns[at]
                .as_ref()
                .ok_or_else(|| lacks(&self.called(o), "return type"))?;
            s.push_str(&format!(" RETURNS {returns}"));
        }
        if t.language[at] != "SQL" {
            s.push_str(&format!("\n    LANGUAGE {}", t.language[at]));
        }
        s.push_str(if t.deterministic[at] {
            "\n    DETERMINISTIC"
        } else {
            "\n    NOT DETERMINISTIC"
        });
        s.push_str(&format!("\n    {}", t.data_access[at]));
        s.push_str(&format!("\n    SQL SECURITY {}", t.security[at]));
        if let Some(comment) = &self.r.objects.comment[o] {
            s.push_str(&format!("\n    COMMENT {}", lit(comment)));
        }
        s.push('\n');
        s.push_str(&t.body[at]);
        Ok(s)
    }

    /// The triggers ordered by table, timing, event and action order, each with the trigger it follows: the one before
    /// it in its group of one table, timing and event (none for the first).
    fn triggers_in_order(&self) -> Result<Vec<(usize, Option<usize>)>, EngineError> {
        type Group = (Uuid, usize, usize);
        type Order = (i32, i32, usize, usize, i32, usize);
        let mut keyed: Vec<(Order, Group, usize)> = Vec::new();
        for o in self.of_kind("trigger") {
            let at = self.engine_row(&self.d.maps.trigger, o, "trigger row")?;
            let table = self.r.objects.parent[o].ok_or_else(|| lacks(&self.called(o), "table"))?;
            let place_of_table = place(&self.d.maps.object, table, &self.called(o), "table")?;
            let t = &self.r.triggers;
            let timing = usize::from(t.timing[at] == "AFTER");
            let event = ["INSERT", "UPDATE", "DELETE"]
                .iter()
                .position(|e| *e == t.event[at])
                .unwrap_or(3);
            keyed.push((
                (
                    self.namespace_position(place_of_table),
                    self.r.objects.position[place_of_table],
                    timing,
                    event,
                    t.action_order[at],
                    o,
                ),
                (table, timing, event),
                o,
            ));
        }
        keyed.sort_by_key(|(order, _, _)| *order);
        let mut out: Vec<(usize, Option<usize>)> = Vec::new();
        let mut previous: Option<(Group, usize)> = None;
        for (_, group, o) in keyed {
            let follows = previous.filter(|(g, _)| *g == group).map(|(_, p)| p);
            out.push((o, follows));
            previous = Some((group, o));
        }
        Ok(out)
    }

    /// A trigger's statement; `follows` is the trigger before it in its group.
    fn trigger(&self, o: usize, follows: Option<usize>) -> Result<String, EngineError> {
        let at = self.engine_row(&self.d.maps.trigger, o, "trigger row")?;
        let t = &self.r.triggers;
        let table = self.r.objects.parent[o].ok_or_else(|| lacks(&self.called(o), "table"))?;
        let table = place(&self.d.maps.object, table, &self.called(o), "table")?;
        let mut s = format!(
            "CREATE DEFINER={} TRIGGER {} {} {} ON {} FOR EACH ROW",
            t.definer[at],
            q(self.name_of(o)),
            t.timing[at],
            t.event[at],
            q(self.name_of(table))
        );
        if let Some(previous) = follows {
            s.push_str(&format!(" FOLLOWS {}", q(self.name_of(previous))));
        }
        s.push('\n');
        s.push_str(&t.body[at]);
        Ok(s)
    }

    fn event(&self, o: usize) -> Result<String, EngineError> {
        let at = self.engine_row(&self.d.maps.event, o, "event row")?;
        let t = &self.r.events;
        let schedule = match (&t.execute_at[at], &t.interval_value[at], &t.interval_field[at]) {
            (Some(when), _, _) => format!("AT {}", lit(when)),
            (None, Some(value), Some(field)) => {
                let value = if value.chars().all(|c| c.is_ascii_digit()) {
                    value.clone()
                } else {
                    lit(value)
                };
                let mut every = format!("EVERY {value} {field}");
                if let Some(starts) = &t.starts[at] {
                    every.push_str(&format!(" STARTS {}", lit(starts)));
                }
                if let Some(ends) = &t.ends[at] {
                    every.push_str(&format!(" ENDS {}", lit(ends)));
                }
                every
            }
            _ => {
                return Err(lacks(
                    &self.called(o),
                    "schedule (a time, or an interval and its field)",
                ));
            }
        };
        let mut s = format!(
            "CREATE DEFINER={} EVENT {} ON SCHEDULE {schedule} ON COMPLETION {} {}",
            t.definer[at],
            q(self.name_of(o)),
            t.on_completion[at],
            t.status[at]
        );
        if let Some(comment) = &self.r.objects.comment[o] {
            s.push_str(&format!(" COMMENT {}", lit(comment)));
        }
        s.push_str(&format!(" DO {}", t.body[at]));
        Ok(s)
    }

    // --- accounts, roles and grants ------------------------------------------------------------------------------------------------

    fn accounts(&mut self) -> Result<(), EngineError> {
        let objects: Vec<usize> = self
            .of_kind("account")
            .into_iter()
            .chain(self.of_kind("role"))
            .collect();
        for o in objects {
            let at = self.engine_row(&self.d.maps.account, o, "account row")?;
            let t = &self.r.accounts;
            let who = format!("{}@{}", lit(&t.user_name[at]), lit(&t.host[at]));
            if self.r.objects.kind[o] == "role" {
                self.statement(&format!("CREATE ROLE {who}"));
                continue;
            }
            let mut s = format!("CREATE USER {who}");
            if let Some(plugin) = &t.auth_plugin[at] {
                s.push_str(&format!(" IDENTIFIED WITH {}", lit(plugin)));
            }
            // The password's hash exactly as the source kept it, so the account signs in as before: a binary hash as the
            // 0x hex literal the server wrote, any other as a string.
            if let Some(hash) = &t.auth_string[at] {
                if t.auth_plugin[at].is_none() {
                    return Err(lacks(
                        &self.called(o),
                        "authentication plugin, which a password's hash needs",
                    ));
                }
                let hex = hash.len() > 2 && hash.starts_with("0x") && hash[2..].chars().all(|c| c.is_ascii_hexdigit());
                s.push_str(&format!(" AS {}", if hex { hash.clone() } else { lit(hash) }));
            }
            match t.ssl_type[at].as_deref() {
                Some("SSL") => s.push_str(" REQUIRE SSL"),
                Some("X509") => s.push_str(" REQUIRE X509"),
                Some("SPECIFIED") => {
                    let mut require = Vec::new();
                    if let Some(v) = &t.x509_issuer[at] {
                        require.push(format!("ISSUER {}", lit(v)));
                    }
                    if let Some(v) = &t.x509_subject[at] {
                        require.push(format!("SUBJECT {}", lit(v)));
                    }
                    if let Some(v) = &t.ssl_cipher[at] {
                        require.push(format!("CIPHER {}", lit(v)));
                    }
                    s.push_str(&format!(" REQUIRE {}", require.join(" AND ")));
                }
                _ => {}
            }
            let mut limits = Vec::new();
            for (name, value) in [
                ("MAX_QUERIES_PER_HOUR", t.max_queries_per_hour[at]),
                ("MAX_UPDATES_PER_HOUR", t.max_updates_per_hour[at]),
                ("MAX_CONNECTIONS_PER_HOUR", t.max_connections_per_hour[at]),
                ("MAX_USER_CONNECTIONS", t.max_user_connections[at]),
            ] {
                if value != 0 {
                    limits.push(format!("{name} {value}"));
                }
            }
            if !limits.is_empty() {
                s.push_str(&format!(" WITH {}", limits.join(" ")));
            }
            if let Some(expire) = &t.password_expire[at] {
                s.push_str(&format!(" PASSWORD EXPIRE {expire}"));
            }
            if let Some(v) = &t.password_history[at] {
                s.push_str(&format!(" PASSWORD HISTORY {v}"));
            }
            if let Some(v) = &t.password_reuse_interval[at] {
                s.push_str(&format!(" PASSWORD REUSE INTERVAL {v}"));
            }
            if let Some(v) = &t.password_require_current[at] {
                s.push_str(&format!(" PASSWORD REQUIRE CURRENT {v}"));
            }
            if let Some(v) = t.failed_login_attempts[at] {
                s.push_str(&format!(" FAILED_LOGIN_ATTEMPTS {v}"));
            }
            if let Some(v) = &t.password_lock_time[at] {
                s.push_str(&format!(" PASSWORD_LOCK_TIME {v}"));
            }
            if t.locked[at] {
                s.push_str(" ACCOUNT LOCK");
            }
            if let Some(v) = &t.attributes[at] {
                s.push_str(&format!(" ATTRIBUTE {}", lit(v)));
            }
            self.statement(&s);
        }
        Ok(())
    }

    fn role_grants(&mut self) -> Result<(), EngineError> {
        let t = &self.r.role_grants;
        let mut defaults: Vec<(Uuid, Vec<String>)> = Vec::new();
        let mut statements = Vec::new();
        for i in 0..t.id.len() {
            let role = self.account(t.role[i])?;
            let grantee = self.account(t.grantee[i])?;
            let admin = if t.admin_option[i] { " WITH ADMIN OPTION" } else { "" };
            statements.push(format!("GRANT {role} TO {grantee}{admin}"));
            if t.is_default[i] {
                match defaults.iter_mut().find(|(g, _)| *g == t.grantee[i]) {
                    Some((_, roles)) => roles.push(role),
                    None => defaults.push((t.grantee[i], vec![role])),
                }
            }
        }
        for s in statements {
            self.statement(&s);
        }
        for (grantee, roles) in defaults {
            let s = format!("SET DEFAULT ROLE {} TO {}", roles.join(", "), self.account(grantee)?);
            self.statement(&s);
        }
        Ok(())
    }

    fn privileges(&mut self) -> Result<(), EngineError> {
        let t = &self.r.privileges;
        let mut groups: Vec<(Target<'a>, Vec<usize>)> = Vec::new();
        let mut places: HashMap<Target<'a>, usize> = HashMap::new();
        for i in 0..t.id.len() {
            let target = Target {
                grantee: t.grantee[i],
                level: t.level[i].as_str(),
                database: t.database_name[i].as_deref(),
                object: t.object_name[i].as_deref(),
                routine_kind: t.routine_kind[i].as_deref(),
                proxied: t.proxied[i],
                grant_option: t.grant_option[i],
            };
            match places.get(&target) {
                Some(&g) => groups[g].1.push(i),
                None => {
                    places.insert(target, groups.len());
                    groups.push((target, vec![i]));
                }
            }
        }
        for (target, members) in groups {
            let grantee = self.account(target.grantee)?;
            let on = match target.level {
                "global" => "*.*".to_string(),
                "database" => format!(
                    "{}.*",
                    q(target
                        .database
                        .ok_or_else(|| lacks("a database privilege", "database"))?)
                ),
                "table" | "column" => format!(
                    "{}.{}",
                    q(target.database.ok_or_else(|| lacks("a table privilege", "database"))?),
                    q(target.object.ok_or_else(|| lacks("a table privilege", "table"))?)
                ),
                "routine" => format!(
                    "{} {}.{}",
                    target
                        .routine_kind
                        .ok_or_else(|| lacks("a routine privilege", "routine kind"))?,
                    q(target
                        .database
                        .ok_or_else(|| lacks("a routine privilege", "database"))?),
                    q(target.object.ok_or_else(|| lacks("a routine privilege", "routine"))?)
                ),
                "proxy" => self.account(
                    target
                        .proxied
                        .ok_or_else(|| lacks("a proxy privilege", "proxied account"))?,
                )?,
                other => {
                    return Err(EngineError::Unsupported(format!("a privilege at the level `{other}`")));
                }
            };
            let t = &self.r.privileges;
            let list = if target.level == "column" {
                let mut per: Vec<(&str, Vec<String>)> = Vec::new();
                for &i in &members {
                    let column = t.column_name[i]
                        .as_deref()
                        .ok_or_else(|| lacks("a column privilege", "column"))?;
                    match per.iter_mut().find(|(p, _)| *p == t.privilege[i]) {
                        Some((_, columns)) => columns.push(q(column)),
                        None => per.push((t.privilege[i].as_str(), vec![q(column)])),
                    }
                }
                per.iter()
                    .map(|(p, columns)| format!("{p} ({})", columns.join(", ")))
                    .collect::<Vec<_>>()
                    .join(", ")
            } else {
                members
                    .iter()
                    .map(|&i| t.privilege[i].as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            let option = if target.grant_option { " WITH GRANT OPTION" } else { "" };
            self.statement(&format!("GRANT {list} ON {on} TO {grantee}{option}"));
        }
        Ok(())
    }

    fn components(&mut self) -> Result<(), EngineError> {
        for o in self.of_kind("component") {
            let at = self.engine_row(&self.d.maps.component, o, "component row")?;
            let s = format!("INSTALL COMPONENT {}", lit(&self.r.components.urn[at]));
            self.statement(&s);
        }
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::load::Maps;

    /// A design built in a test: a server, a database `shop`, and what a test adds to it.
    pub(crate) struct Fixture {
        pub(crate) rows: Rows,
        pub(crate) design: Uuid,
        database: Uuid,
        next: i32,
    }

    impl Fixture {
        pub(crate) fn new() -> Fixture {
            Fixture::of(Uuid::now_v7())
        }

        /// The same, for a design that exists in a store.
        pub(crate) fn of(design: Uuid) -> Fixture {
            let mut rows = Rows::default();
            let server = Uuid::now_v7();
            let database = Uuid::now_v7();
            for (id, parent, name, position) in [(server, None, "server", 1), (database, Some(server), "shop", 1)] {
                rows.namespaces.id.push(id);
                rows.namespaces.design.push(design);
                rows.namespaces.parent.push(parent);
                rows.namespaces.name.push(name.to_string());
                rows.namespaces.position.push(position);
                rows.namespaces.comment.push(None);
            }
            rows.databases.id.push(database);
            rows.databases.design.push(design);
            rows.databases.character_set.push("utf8mb4".to_string());
            rows.databases.collation.push("utf8mb4_0900_ai_ci".to_string());
            rows.databases.encryption.push(None);
            rows.databases.read_only.push(None);
            Fixture {
                rows,
                design,
                database,
                next: 0,
            }
        }

        fn object(&mut self, kind: &str, name: &str, parent: Option<Uuid>) -> Uuid {
            let id = Uuid::now_v7();
            self.next += 1;
            let o = &mut self.rows.objects;
            o.id.push(id);
            o.design.push(self.design);
            o.engine.push("mysql".to_string());
            o.namespace.push(self.database);
            o.kind.push(kind.to_string());
            o.name.push(name.to_string());
            o.signature.push(String::new());
            o.parent.push(parent);
            o.position.push(self.next);
            o.comment.push(None);
            o.notes.push(None);
            id
        }

        fn view(&mut self, name: &str, reads: &[Uuid]) -> Uuid {
            let id = self.object("view", name, None);
            let v = &mut self.rows.views;
            v.id.push(id);
            v.design.push(self.design);
            v.definition.push("select 1".to_string());
            v.algorithm.push("UNDEFINED".to_string());
            v.definer.push("`root`@`%`".to_string());
            v.security.push("DEFINER".to_string());
            v.check_option.push(None);
            v.character_set_client.push("utf8mb4".to_string());
            v.collation_connection.push("utf8mb4_0900_ai_ci".to_string());
            for (n, target) in reads.iter().enumerate() {
                let d = &mut self.rows.dependencies;
                d.id.push(Uuid::now_v7());
                d.design.push(self.design);
                d.object.push(id);
                d.uses.push(*target);
                d.r#as.push("reads".to_string());
                d.position.push(i32::try_from(n).unwrap() + 1);
            }
            id
        }

        fn routine(&mut self, kind: &str, name: &str, returns: Option<&str>) {
            let id = self.object(kind, name, None);
            let r = &mut self.rows.routines;
            r.id.push(id);
            r.design.push(self.design);
            r.parameter_list.push(String::new());
            r.returns.push(returns.map(str::to_string));
            r.deterministic.push(true);
            r.data_access.push("NO SQL".to_string());
            r.security.push("DEFINER".to_string());
            r.definer.push("`root`@`%`".to_string());
            r.language.push("SQL".to_string());
            r.body.push("BEGIN END".to_string());
            r.sql_mode.push(String::new());
            r.character_set_client.push("utf8mb4".to_string());
            r.collation_connection.push("utf8mb4_0900_ai_ci".to_string());
            r.database_collation.push("utf8mb4_0900_ai_ci".to_string());
        }

        fn trigger(&mut self, name: &str, table: Uuid, timing: &str, event: &str, order: i32) {
            let id = self.object("trigger", name, Some(table));
            let t = &mut self.rows.triggers;
            t.id.push(id);
            t.design.push(self.design);
            t.timing.push(timing.to_string());
            t.event.push(event.to_string());
            t.action_order.push(order);
            t.body.push("SET NEW.a = 1".to_string());
            t.definer.push("`root`@`%`".to_string());
            t.sql_mode.push(String::new());
            t.character_set_client.push("utf8mb4".to_string());
            t.collation_connection.push("utf8mb4_0900_ai_ci".to_string());
            t.database_collation.push("utf8mb4_0900_ai_ci".to_string());
        }

        pub(crate) fn table(&mut self, name: &str) -> Uuid {
            let id = self.object("table", name, None);
            let c = Uuid::now_v7();
            let t = &mut self.rows.columns;
            t.id.push(c);
            t.design.push(self.design);
            t.object.push(id);
            t.position.push(1);
            t.name.push("a".to_string());
            t.r#type.push("int".to_string());
            t.nullable.push(false);
            t.default_value.push(None);
            t.generated_expression.push(None);
            t.generated_stored.push(None);
            t.collation.push(None);
            t.comment.push(None);
            let o = &mut self.rows.column_options;
            o.id.push(c);
            o.design.push(self.design);
            o.character_set.push(None);
            o.default_is_expression.push(false);
            o.on_update.push(None);
            o.auto_increment.push(false);
            o.invisible.push(false);
            o.srid.push(None);
            o.column_format.push(None);
            o.storage.push(None);
            o.compression_dictionary.push(None);
            o.engine_attribute.push(None);
            o.secondary_engine_attribute.push(None);
            let t = &mut self.rows.tables;
            t.id.push(id);
            t.design.push(self.design);
            t.engine.push("InnoDB".to_string());
            t.collation.push("utf8mb4_0900_ai_ci".to_string());
            t.row_format.push(None);
            t.auto_increment.push(None);
            t.avg_row_length.push(None);
            t.min_rows.push(None);
            t.max_rows.push(None);
            t.pack_keys.push(None);
            t.checksum.push(None);
            t.delay_key_write.push(None);
            t.key_block_size.push(None);
            t.stats_persistent.push(None);
            t.stats_auto_recalc.push(None);
            t.stats_sample_pages.push(None);
            t.compression.push(None);
            t.encryption.push(None);
            t.tablespace.push(None);
            t.storage.push(None);
            t.data_directory.push(None);
            t.index_directory.push(None);
            t.autoextend_size.push(None);
            t.engine_attribute.push(None);
            t.secondary_engine.push(None);
            t.secondary_engine_attribute.push(None);
            t.insert_method.push(None);
            t.connection.push(None);
            id
        }

        fn design(self) -> Design {
            let maps = Maps::of(&self.rows);
            Design {
                id: self.design,
                rows: self.rows,
                maps,
            }
        }
    }

    #[test]
    fn views_in_a_cycle_are_an_error_naming_them() {
        let mut f = Fixture::new();
        let a = f.view("a", &[]);
        let b = f.view("b", &[a]);
        // a reads b, which reads a.
        let d = &mut f.rows.dependencies;
        d.id.push(Uuid::now_v7());
        d.design.push(f.design);
        d.object.push(a);
        d.uses.push(b);
        d.r#as.push("reads".to_string());
        d.position.push(1);
        let error = write(&f.design()).unwrap_err().to_string();
        assert!(error.contains("`shop`.`a`") && error.contains("`shop`.`b`"), "{error}");
    }

    #[test]
    fn views_come_after_the_views_they_read() {
        let mut f = Fixture::new();
        let a = f.view("a", &[]);
        f.view("b", &[a]);
        let sql = write(&f.design()).unwrap();
        assert!(sql.find("VIEW `a`").unwrap() < sql.find("VIEW `b`").unwrap());
    }

    #[test]
    fn a_function_without_its_return_type_is_an_error_naming_it() {
        let mut f = Fixture::new();
        f.routine("function", "price", None);
        let error = write(&f.design()).unwrap_err().to_string();
        assert!(
            error.contains("the function shop.price") && error.contains("return type"),
            "{error}"
        );
    }

    #[test]
    fn triggers_on_one_table_follow_each_other_in_action_order() {
        let mut f = Fixture::new();
        let t = f.table("t");
        // Made out of order, in two groups.
        f.trigger("second", t, "BEFORE", "INSERT", 2);
        f.trigger("first", t, "BEFORE", "INSERT", 1);
        f.trigger("after", t, "AFTER", "INSERT", 1);
        let sql = write(&f.design()).unwrap();
        let first = sql.find("TRIGGER `first`").unwrap();
        let second = sql.find("TRIGGER `second`").unwrap();
        let after = sql.find("TRIGGER `after`").unwrap();
        assert!(first < second && second < after, "BEFORE triggers in order, then AFTER");
        assert!(sql.contains("TRIGGER `second` BEFORE INSERT ON `t` FOR EACH ROW FOLLOWS `first`"));
        assert!(!sql.contains("`first` BEFORE INSERT ON `t` FOR EACH ROW FOLLOWS"));
        assert!(!sql.contains("`after` AFTER INSERT ON `t` FOR EACH ROW FOLLOWS"));
        assert!(sql.contains("DELIMITER $sf_end$"));
        assert!(
            sql.trim_end()
                .ends_with("DELIMITER ;\nSET NAMES utf8mb4;\nSET sql_mode = 'NO_ENGINE_SUBSTITUTION';"),
            "the programs' sessions end with the delimiter"
        );
    }

    #[test]
    fn the_statements_come_in_the_fixed_order() {
        let mut f = Fixture::new();
        f.table("t");
        let sql = write(&f.design()).unwrap();
        let order = [
            "SET NAMES utf8mb4;",
            "SET FOREIGN_KEY_CHECKS = 0;",
            "CREATE DATABASE `shop`",
            "CREATE TABLE `t`",
            "SET FOREIGN_KEY_CHECKS = 1;",
        ];
        let at: Vec<usize> = order.iter().map(|s| sql.find(s).unwrap()).collect();
        assert!(at.windows(2).all(|w| w[0] < w[1]), "{sql}");
    }
}
