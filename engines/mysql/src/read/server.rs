//! What a server holds beside its tables: a database's own options, general tablespaces and spatial reference systems.

use schema_forge_engine::sections::Options;
use serde_json::json;
use sqlparser::tokenizer::Token;

use crate::lex::Cursor;

/// Reads `CREATE DATABASE`, the cursor after `DATABASE` or `SCHEMA`: its name and options.
///
/// # Errors
/// When an option is not one a database has.
pub fn database(c: &mut Cursor<'_>) -> Result<(String, Options), String> {
    c.eat_kws(&["IF", "NOT", "EXISTS"]);
    let name = c.name()?;
    let mut o = Options::new();
    loop {
        c.eat(&Token::Comma);
        let default = c.eat_kw("DEFAULT");
        if c.eat_kws(&["CHARACTER", "SET"]) || c.eat_kw("CHARSET") {
            o.insert("charset".into(), json!(c.value()?));
        } else if c.eat_kw("COLLATE") {
            o.insert("collation".into(), json!(c.value()?));
        } else if c.eat_kw("ENCRYPTION") {
            o.insert("encryption".into(), json!(c.value()?.eq_ignore_ascii_case("Y")));
        } else if !default && c.eat_kws(&["READ", "ONLY"]) {
            o.insert("read_only".into(), json!(c.value()? == "1"));
        } else if !default && c.is_done() {
            return Ok((name, o));
        } else {
            return Err(format!("not an option of a database: {}", c.here()));
        }
    }
}

/// Reads `CREATE TABLESPACE`, the cursor after `TABLESPACE`.
///
/// # Errors
/// When an option is not one a general tablespace has (an NDB tablespace's are kept as written).
pub fn tablespace(c: &mut Cursor<'_>) -> Result<(String, Options), String> {
    let name = c.name()?;
    let mut o = Options::new();
    loop {
        if c.eat_kws(&["ADD", "DATAFILE"]) {
            o.insert("datafile".into(), json!(c.string()?));
        } else if c.eat_kw("AUTOEXTEND_SIZE") {
            o.insert("autoextend_size".into(), json!(c.value()?));
        } else if c.eat_kw("FILE_BLOCK_SIZE") {
            o.insert("file_block_size".into(), json!(c.value()?));
        } else if c.eat_kw("ENCRYPTION") {
            o.insert("encryption".into(), json!(c.value()?));
        } else if c.eat_kw("ENGINE_ATTRIBUTE") {
            o.insert("engine_attribute".into(), json!(c.value()?));
        } else if c.eat_kws(&["STORAGE", "ENGINE"]) || c.eat_kw("ENGINE") {
            o.insert("engine".into(), json!(c.value()?));
        } else if c.is_done() {
            return Ok((name, o));
        } else {
            return Err(format!("not an option of a general tablespace: {}", c.here()));
        }
    }
}

/// A spatial reference system: its name, its description, and its options.
#[derive(Debug)]
pub struct Srs {
    pub name: String,
    pub description: Option<String>,
    pub options: Options,
}

/// Reads `CREATE SPATIAL REFERENCE SYSTEM`, the cursor after `SYSTEM`.
///
/// # Errors
/// When it has no name or definition.
pub fn srs(c: &mut Cursor<'_>) -> Result<Srs, String> {
    c.eat_kws(&["IF", "NOT", "EXISTS"]);
    let mut o = Options::new();
    o.insert("srid".into(), json!(c.number()?));
    let (mut name, mut description) = (None, None);
    loop {
        if c.eat_kw("NAME") {
            name = Some(c.string()?);
        } else if c.eat_kw("DEFINITION") {
            o.insert("definition".into(), json!(c.string()?));
        } else if c.eat_kw("ORGANIZATION") {
            o.insert("organization".into(), json!(c.string()?));
            c.expect_kw("IDENTIFIED")?;
            c.expect_kw("BY")?;
            o.insert("organization_srid".into(), json!(c.number()?));
        } else if c.eat_kw("DESCRIPTION") {
            description = Some(c.string()?);
        } else if c.is_done() {
            break;
        } else {
            return Err(format!("not a clause of a spatial reference system: {}", c.here()));
        }
    }
    match (name, o.contains_key("definition")) {
        (Some(name), true) => Ok(Srs { name, description, options: o }),
        _ => Err("a spatial reference system without a name or a definition".to_string()),
    }
}

/// A statement without its credentials: every `IDENTIFIED …` clause (an account's password, or a grant's in old
/// MySQL) and every `PASSWORD '…'` (a server's) cut out. With `lock`, an account whose password was cut is kept locked,
/// so that what is written back never makes an account that signs in without a password. A credential is never kept.
///
/// # Errors
/// When a clause is not complete: the statement is then not kept at all.
pub fn without_credentials(text: &str, lock: bool) -> Result<String, String> {
    let mut c = Cursor::new(text)?;
    let mut parts: Vec<&str> = Vec::new();
    let mut from = 0;
    let mut cut = false;
    while !c.is_done() {
        let start = c.mark();
        if c.peek_kw("IDENTIFIED") {
            parts.push(c.slice(from, start));
            loop {
                c.expect_kw("IDENTIFIED")?;
                if c.eat_kw("WITH") {
                    if matches!(c.peek(), Some(Token::SingleQuotedString(_) | Token::DoubleQuotedString(_))) {
                        c.string()?;
                    } else {
                        c.name()?;
                    }
                }
                if c.eat_kw("BY") || c.eat_kw("AS") {
                    if c.eat_kws(&["RANDOM", "PASSWORD"]) {
                    } else {
                        c.eat_kw("PASSWORD");
                        c.string()?;
                    }
                }
                if !(c.peek_kw("AND") && c.peek_kw_at(1, "IDENTIFIED")) {
                    break;
                }
                c.next();
            }
            from = c.mark();
            cut = true;
        } else if c.peek_kw("PASSWORD")
            && matches!(c.peek_at(1), Some(Token::SingleQuotedString(_) | Token::DoubleQuotedString(_)))
        {
            // A server's option, `PASSWORD 'secret'`, and the comma that joins it to the others.
            let comma_before = start > from && c.is_token_at(start - 1, &Token::Comma);
            parts.push(c.slice(from, if comma_before { start - 1 } else { start }));
            c.next();
            c.next();
            if !comma_before {
                c.eat(&Token::Comma);
            }
            from = c.mark();
            cut = true;
        } else {
            c.next();
        }
    }
    parts.push(c.slice(from, c.len()));
    let mut out = parts.into_iter().filter(|p| !p.is_empty()).collect::<Vec<_>>().join(" ");
    if lock && cut && !out.to_ascii_uppercase().contains(" ACCOUNT ") {
        out.push_str(" ACCOUNT LOCK");
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_credential_is_never_kept() {
        assert_eq!(
            without_credentials("CREATE USER 'r'@'%' IDENTIFIED BY 'hunter2' REQUIRE SSL", true).as_deref(),
            Ok("CREATE USER 'r'@'%' REQUIRE SSL ACCOUNT LOCK")
        );
        assert_eq!(
            without_credentials("GRANT ALL ON db.* TO 'r'@'%' IDENTIFIED BY PASSWORD '*94BDCEBE19'", false).as_deref(),
            Ok("GRANT ALL ON db.* TO 'r'@'%'")
        );
        assert_eq!(
            without_credentials(
                "CREATE SERVER s FOREIGN DATA WRAPPER mysql OPTIONS (USER 'u', PASSWORD 'p', PORT 3306)",
                false
            )
            .as_deref(),
            Ok("CREATE SERVER s FOREIGN DATA WRAPPER mysql OPTIONS (USER 'u' , PORT 3306)")
        );
        assert_eq!(
            without_credentials("CREATE USER x COMMENT 'two  spaces' IDENTIFIED BY 'p'", true).as_deref(),
            Ok("CREATE USER x COMMENT 'two  spaces' ACCOUNT LOCK"),
            "the rest is kept exactly"
        );
        let two = without_credentials(
            "CREATE USER a IDENTIFIED WITH caching_sha2_password AS 'hash' , b IDENTIFIED BY 'x' AND IDENTIFIED WITH \
             authentication_fido ACCOUNT UNLOCK",
            true,
        )
        .expect("read");
        assert!(!two.contains("hash") && !two.contains("'x'") && two.ends_with("ACCOUNT UNLOCK"), "{two}");
        assert_eq!(
            without_credentials("CREATE USER 'app'@'localhost'", true).as_deref(),
            Ok("CREATE USER 'app'@'localhost'")
        );
    }
}
