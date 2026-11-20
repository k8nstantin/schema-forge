//! PostgreSQL types: from the tokens of a column definition to the model's structured type, and back.

use std::collections::HashMap;

use schema_forge_core::{DataType, Id};
use sqlparser::tokenizer::Token;

use crate::cursor::{Case, Cur, ident_of};

/// Reads the type in tokens `from..to`. `types` resolves user-defined types by `(namespace, name)`.
pub fn read(cur: &Cur<'_>, from: usize, to: usize, types: &HashMap<(String, String), Id>) -> DataType {
    let text = cur.text(from, to).trim();
    let toks = &cur.toks()[from..to];
    parse(toks, types).unwrap_or_else(|| DataType::verbatim(text))
}

fn parse(toks: &[crate::split::Tok], types: &HashMap<(String, String), Id>) -> Option<DataType> {
    let mut i = 0;
    // A qualified or quoted name is a user-defined type.
    let first = &toks.first()?.token;
    let qualified = toks.get(1).is_some_and(|t| t.token == Token::Period);
    let quoted = matches!(first, Token::Word(w) if w.quote_style.is_some());
    let mut base = if qualified || quoted {
        let mut parts = vec![ident_of(first, Case::FoldLower)?];
        i = 1;
        while toks.get(i).is_some_and(|t| t.token == Token::Period) {
            parts.push(ident_of(&toks.get(i + 1)?.token, Case::FoldLower)?);
            i += 2;
        }
        let (ns, name) = match parts.as_slice() {
            [name] => ("public".to_string(), name.clone()),
            [ns, name] => (ns.clone(), name.clone()),
            _ => return None,
        };
        let id = types.get(&(ns, name))?;
        DataType { name: "user".to_string(), user_type: Some(id.clone()), ..DataType::default() }
    } else {
        let mut words = Vec::new();
        while let Some(Token::Word(w)) = toks.get(i).map(|t| &t.token) {
            if w.quote_style.is_some() {
                break;
            }
            words.push(w.value.to_lowercase());
            i += 1;
        }
        let mut args = Vec::new();
        if toks.get(i).is_some_and(|t| t.token == Token::LParen) {
            i += 1;
            loop {
                match toks.get(i).map(|t| &t.token) {
                    Some(Token::Number(n, _)) => args.push(n.parse::<i64>().ok()?),
                    Some(Token::Comma) => {}
                    Some(Token::RParen) => {
                        i += 1;
                        break;
                    }
                    _ => return None,
                }
                i += 1;
            }
        }
        // `with time zone` / `without time zone` after `timestamp(6)`.
        while let Some(Token::Word(w)) = toks.get(i).map(|t| &t.token) {
            if w.quote_style.is_some() {
                break;
            }
            words.push(w.value.to_lowercase());
            i += 1;
        }
        base_type(&words.join(" "), &args)?
    };
    // `[]`, `[][]`: an array of the base type.
    let mut dims = 0u32;
    while toks.get(i).is_some_and(|t| t.token == Token::LBracket) {
        i += 1;
        while toks.get(i).is_some_and(|t| matches!(t.token, Token::Number(..))) {
            i += 1;
        }
        if toks.get(i).is_none_or(|t| t.token != Token::RBracket) {
            return None;
        }
        i += 1;
        dims += 1;
    }
    if i != toks.len() {
        return None;
    }
    if dims > 0 {
        base = DataType {
            name: "array".to_string(),
            of: Some(Box::new(base)),
            dimensions: (dims > 1).then_some(dims),
            ..DataType::default()
        };
    }
    Some(base)
}

fn base_type(words: &str, args: &[i64]) -> Option<DataType> {
    let len = |n: usize| args.get(n).and_then(|v| u32::try_from(*v).ok());
    let scale = |n: usize| args.get(n).and_then(|v| i32::try_from(*v).ok());
    let mut t = DataType::default();
    let (name, tz) = match words {
        "character varying" | "varchar" => ("varchar", false),
        "character" | "char" | "bpchar" => ("char", false),
        "integer" | "int" | "int4" => ("integer", false),
        "bigint" | "int8" => ("bigint", false),
        "smallint" | "int2" => ("smallint", false),
        "boolean" | "bool" => ("boolean", false),
        "double precision" | "float8" => ("double precision", false),
        "real" | "float4" => ("real", false),
        "numeric" | "decimal" => ("numeric", false),
        "timestamp" | "timestamp without time zone" => ("timestamp", false),
        "timestamp with time zone" | "timestamptz" => ("timestamp", true),
        "time" | "time without time zone" => ("time", false),
        "time with time zone" | "timetz" => ("time", true),
        "bit varying" | "varbit" => ("varbit", false),
        "serial" | "serial4" => ("serial", false),
        "bigserial" | "serial8" => ("bigserial", false),
        "smallserial" | "serial2" => ("smallserial", false),
        other if schema_forge_core::types::known(schema_forge_core::Target::Postgres, other) => (other, false),
        _ => return None,
    };
    t.name = name.to_string();
    t.with_time_zone = tz;
    match name {
        "varchar" | "char" | "bit" | "varbit" => t.length = len(0),
        "numeric" => {
            t.precision = len(0);
            t.scale = scale(1);
        }
        "timestamp" | "time" => t.precision = len(0),
        "interval" if !args.is_empty() => t.precision = len(0),
        _ if !args.is_empty() => return None,
        _ => {}
    }
    Some(t)
}

/// The type as PostgreSQL writes it (`character varying(200)`, `timestamp(6) with time zone`, `text[]`).
#[must_use]
pub fn write(t: &DataType, type_names: &HashMap<Id, String>) -> String {
    if t.is_verbatim() {
        return t.text.clone().unwrap_or_default();
    }
    let args = |v: &[Option<String>]| {
        let v: Vec<String> = v.iter().flatten().cloned().collect();
        if v.is_empty() { String::new() } else { format!("({})", v.join(",")) }
    };
    match t.name.as_str() {
        "array" => {
            let inner = t.of.as_deref().map(|o| write(o, type_names)).unwrap_or_default();
            format!("{inner}{}", "[]".repeat(t.dimensions.unwrap_or(1) as usize))
        }
        "user" => t.user_type.as_ref().and_then(|id| type_names.get(id)).cloned().unwrap_or_default(),
        "varchar" => format!("character varying{}", args(&[t.length.map(|l| l.to_string())])),
        "char" => format!("character{}", args(&[t.length.map(|l| l.to_string())])),
        "bit" | "varbit" => {
            let name = if t.name == "bit" { "bit" } else { "bit varying" };
            format!("{name}{}", args(&[t.length.map(|l| l.to_string())]))
        }
        "numeric" => format!("numeric{}", args(&[t.precision.map(|p| p.to_string()), t.scale.map(|s| s.to_string())])),
        "timestamp" | "time" | "interval" => {
            let zone = match (t.name.as_str(), t.with_time_zone) {
                ("interval", _) => "",
                (_, true) => " with time zone",
                (_, false) => " without time zone",
            };
            format!("{}{}{zone}", t.name, args(&[t.precision.map(|p| p.to_string())]))
        }
        other => other.to_string(),
    }
}
