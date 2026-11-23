//! What makes a schema wrong for MySQL at its version, beyond the model's own checks. Each check is a fact MySQL
//! refuses; what is only deprecated is read, kept and written as it is.

use schema_forge_engine::sections::{self, ColumnSection, LinkSection, ObjectSection};
use schema_forge_model::{Id, Object, Problem, Schema};
use serde_json::Value;

use crate::kinds::TABLE;
use crate::versions;

/// MySQL's longest name of a database, a table, a column, an index or a routine.
const LONGEST_NAME: usize = 64;

/// Everything that makes `schema` wrong for MySQL at its version.
#[must_use]
pub fn check(schema: &Schema) -> Vec<Problem> {
    let version = schema.engine.version.as_str();
    let mut out = Vec::new();
    let mut problem = |at: &Id, message: String| out.push(Problem { at: Some(at.clone()), message });
    for n in &schema.namespaces {
        if n.name.chars().count() > LONGEST_NAME {
            problem(&n.id, format!("`{}` is longer than {LONGEST_NAME} characters", n.name));
        }
    }
    for o in &schema.objects {
        if o.name.chars().count() > LONGEST_NAME {
            problem(&o.id, format!("`{}` is longer than {LONGEST_NAME} characters", o.name));
        }
        for c in &o.columns {
            if c.name.chars().count() > LONGEST_NAME {
                problem(&c.id, format!("`{}.{}` is longer than {LONGEST_NAME} characters", o.name, c.name));
            }
        }
        let Ok(s) = sections::read::<ObjectSection>(&o.engine) else { continue };
        if o.kind == TABLE {
            table(o, &s, version, &mut problem);
        }
        if let Some(t) = &s.trigger
            && schema.object(&t.table).is_some_and(|x| x.kind != TABLE)
        {
            problem(&o.id, format!("`{}` is a trigger on a view: MySQL's triggers are on tables", o.name));
        }
    }
    for l in &schema.links {
        let Ok(s) = sections::read::<LinkSection>(&l.engine) else { continue };
        let inline = s.options.get("inline") == Some(&Value::Bool(true));
        if !s.enforced && (!inline || versions::has(version, &versions::INLINE_REFERENCES)) {
            problem(
                &l.id,
                "MySQL cannot hold a link it does not enforce: before 9.0 only on one column, written on it"
                    .to_string(),
            );
        }
        if !versions::has(version, &versions::NONSTANDARD_FOREIGN_KEY)
            && let Some(parent) = schema.object(&l.to.object)
            && !is_key(parent, &l.to.columns)
        {
            problem(
                &l.id,
                format!(
                    "from 8.4 a foreign key refers to a primary key or a unique of `{}`, whole: these columns are neither",
                    parent.name
                ),
            );
        }
    }
    out
}

fn table(o: &Object, s: &ObjectSection, version: &str, problem: &mut impl FnMut(&Id, String)) {
    let column = |id: &Id| o.columns.iter().find(|c| &c.id == id);
    let section = |id: &Id| column(id).and_then(|c| sections::read::<ColumnSection>(&c.engine).ok());
    let base = |id: &Id| column(id).map(|c| c.data_type.split(['(', ' ']).next().unwrap_or("").to_string());
    let numbered: Vec<&Id> =
        o.columns.iter().filter(|c| section(&c.id).is_some_and(|x| x.identity.is_some())).map(|c| &c.id).collect();
    if numbered.len() > 1 {
        problem(&o.id, format!("`{}` has {} AUTO_INCREMENT columns; MySQL allows one", o.name, numbered.len()));
    }
    // Every key and index, as its columns in order.
    let mut keys: Vec<Vec<&Id>> =
        s.keys.primary.iter().chain(&s.keys.unique).map(|k| k.columns.iter().collect()).collect();
    for i in &s.indexes {
        keys.push(i.parts.iter().filter_map(|p| p.column.as_ref()).collect());
    }
    for id in &numbered {
        if !keys.iter().any(|k| k.first() == Some(id)) {
            problem(id, format!("`{}`: an AUTO_INCREMENT column is the first column of a key", o.name));
        }
        if !versions::has(version, &versions::AUTO_INCREMENT_FLOAT)
            && base(id).is_some_and(|b| b == "float" || b == "double")
        {
            problem(id, "from 8.4 AUTO_INCREMENT is not allowed on a float or a double".to_string());
        }
    }
    let vector = |id: &Id| base(id).is_some_and(|b| b == "vector");
    for k in &keys {
        if let Some(v) = k.iter().find(|id| vector(id)) {
            problem(v, format!("`{}`: a vector is never part of a key or an index", o.name));
        }
    }
    if let Some(p) = &s.partitioning
        && let Some(v) = p.by.iter().filter_map(|f| f.column.as_ref()).find(|id| vector(id))
    {
        problem(v, format!("`{}`: a vector is never part of the partitioning", o.name));
    }
    // A text or a blob is indexed by a prefix, except in a full-text index.
    let long = |id: &Id| base(id).is_some_and(|b| b.ends_with("text") || b.ends_with("blob"));
    for k in s.keys.primary.iter().chain(&s.keys.unique) {
        let lengths = k.options.get("parts").and_then(Value::as_array);
        for (n, id) in k.columns.iter().enumerate() {
            let prefixed = lengths.and_then(|a| a.get(n)).and_then(|p| p.get("length")).is_some();
            if long(id) && !prefixed {
                problem(id, format!("`{}`: a text or a blob in a key needs a prefix length", o.name));
            }
        }
    }
    for i in s.indexes.iter().filter(|i| i.method.as_deref() != Some("fulltext")) {
        for p in &i.parts {
            if let Some(id) = &p.column
                && long(id)
                && !p.options.contains_key("length")
            {
                problem(id, format!("`{}`: a text or a blob in the index `{}` needs a prefix length", o.name, i.name));
            }
        }
    }
    if !versions::has(version, &versions::PARTITION_KEY_PREFIX)
        && let (Some(p), Some(pk)) = (&s.partitioning, &s.keys.primary)
        && p.strategy.as_deref() == Some("key")
    {
        let lengths = pk.options.get("parts").and_then(Value::as_array);
        for f in p.by.iter().filter_map(|f| f.column.as_ref()) {
            let at = pk.columns.iter().position(|c| c == f);
            if at.and_then(|n| lengths.and_then(|a| a.get(n))).and_then(|x| x.get("length")).is_some() {
                problem(f, format!("from 8.4 `{}` is not partitioned by a column with a prefix in its key", o.name));
            }
        }
    }
}

/// Whether `columns` are exactly a primary key or a unique of `o`.
fn is_key(o: &Object, columns: &[Id]) -> bool {
    let Ok(s) = sections::read::<ObjectSection>(&o.engine) else { return false };
    let whole = |k: &sections::Key| k.columns == columns && !k.options.contains_key("parts");
    s.keys.primary.iter().chain(&s.keys.unique).any(whole)
        || s.indexes.iter().any(|i| {
            i.unique
                && i.parts.iter().map(|p| p.column.as_ref()).collect::<Vec<_>>()
                    == columns.iter().map(Some).collect::<Vec<_>>()
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::read;
    use crate::types::BUILT_IN;

    fn problems(version: &str, sql: &str) -> Vec<String> {
        let header = format!("-- MySQL {version} schema, written by Schema Forge\n{sql}");
        let imported = read::read(BUILT_IN, header, version).expect("it reads");
        assert!(imported.report.not_understood.is_empty(), "{:?}", imported.report.not_understood);
        check(&imported.schema).into_iter().map(|p| p.message).collect()
    }

    #[test]
    fn each_refusal_is_found() {
        assert!(
            problems("8.4", "CREATE TABLE t (a int NOT NULL AUTO_INCREMENT, b int NOT NULL AUTO_INCREMENT, KEY (a));")
                .iter()
                .any(|p| p.contains("2 AUTO_INCREMENT columns"))
        );
        assert!(
            problems("8.4", "CREATE TABLE t (a int NOT NULL AUTO_INCREMENT, b int, KEY (b));")
                .iter()
                .any(|p| p.contains("first column of a key"))
        );
        assert!(
            problems("8.4", "CREATE TABLE t (a double NOT NULL AUTO_INCREMENT, PRIMARY KEY (a));")
                .iter()
                .any(|p| p.contains("float or a double"))
        );
        assert!(problems("8.0", "CREATE TABLE t (a double NOT NULL AUTO_INCREMENT, PRIMARY KEY (a));").is_empty());
        assert!(
            problems("9.7", "CREATE TABLE t (v vector(3) NOT NULL, KEY (v));").iter().any(|p| p.contains("vector"))
        );
        assert!(problems("8.4", "CREATE TABLE t (a text, KEY (a));").iter().any(|p| p.contains("prefix length")));
        assert!(problems("8.4", "CREATE TABLE t (a text, KEY (a(10)), FULLTEXT KEY f (a));").is_empty());
        let fk = "CREATE TABLE p (a int NOT NULL, b int, PRIMARY KEY (a), KEY (b));\n\
                  CREATE TABLE c (x int, CONSTRAINT f FOREIGN KEY (x) REFERENCES p (b));";
        assert!(problems("8.4", fk).iter().any(|p| p.contains("primary key or a unique")));
        assert!(problems("8.0", fk).is_empty());
    }

    #[test]
    fn a_long_name_is_refused() {
        let long = "x".repeat(65);
        assert!(
            problems("8.4", &format!("CREATE TABLE `{long}` (a int);")).iter().any(|p| p.contains("longer than 64"))
        );
    }
}
