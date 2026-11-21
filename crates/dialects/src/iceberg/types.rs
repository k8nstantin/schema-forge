//! Iceberg types in Spark SQL: `BIGINT`, `DECIMAL(12,2)`, `ARRAY<STRING>`, `MAP<STRING, BIGINT>`,
//! `STRUCT<`a`: STRING NOT NULL COMMENT '…', …>`.

use schema_forge_core::{DataType, StructField};
use sqlparser::tokenizer::Token;

use crate::cursor::{Case, ident_of, is_kw, string_of};
use crate::split::Tok;

/// Reads a type from `toks`; `None` when it is not one the model describes.
pub fn read(toks: &[Tok]) -> Option<DataType> {
    let mut p = Parser { toks: expand(toks), i: 0 };
    let t = p.data_type()?;
    (p.i == p.toks.len()).then_some(t)
}

/// `>>` and `>>>` close several brackets at once; the tokenizer reads them as shift operators.
fn expand(toks: &[Tok]) -> Vec<Token> {
    let mut out = Vec::new();
    for t in toks {
        match &t.token {
            Token::ShiftRight => out.extend([Token::Gt, Token::Gt]),
            other => out.push(other.clone()),
        }
    }
    out
}

struct Parser {
    toks: Vec<Token>,
    i: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Token> {
        self.toks.get(self.i)
    }

    fn eat(&mut self, t: &Token) -> bool {
        if self.peek() == Some(t) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    fn kw(&mut self, kw: &str) -> bool {
        if self.peek().is_some_and(|t| is_kw(t, kw)) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    fn number(&mut self) -> Option<u32> {
        match self.peek()? {
            Token::Number(n, _) => {
                let v = n.parse().ok()?;
                self.i += 1;
                Some(v)
            }
            _ => None,
        }
    }

    fn data_type(&mut self) -> Option<DataType> {
        let Token::Word(w) = self.peek()?.clone() else { return None };
        if w.quote_style.is_some() {
            return None;
        }
        self.i += 1;
        let name = w.value.to_uppercase();
        let simple = |n: &str| Some(DataType::named(n));
        match name.as_str() {
            "BOOLEAN" => simple("boolean"),
            "TINYINT" | "SMALLINT" | "INT" | "INTEGER" => simple("int"),
            "BIGINT" | "LONG" => simple("long"),
            "FLOAT" | "REAL" => simple("float"),
            "DOUBLE" => simple("double"),
            "DATE" => simple("date"),
            "TIMESTAMP" | "TIMESTAMP_LTZ" => simple("timestamptz"),
            "TIMESTAMP_NTZ" => simple("timestamp"),
            "BINARY" => simple("binary"),
            "VARIANT" => simple("variant"),
            "STRING" => simple("string"),
            "VARCHAR" | "CHAR" => {
                // Iceberg has no lengths: a string.
                if self.eat(&Token::LParen) {
                    self.number()?;
                    if !self.eat(&Token::RParen) {
                        return None;
                    }
                }
                simple("string")
            }
            "DECIMAL" | "NUMERIC" | "DEC" => {
                let mut t = DataType::named("decimal");
                if self.eat(&Token::LParen) {
                    t.precision = Some(self.number()?);
                    if self.eat(&Token::Comma) {
                        t.scale = Some(i32::try_from(self.number()?).ok()?);
                    }
                    if !self.eat(&Token::RParen) {
                        return None;
                    }
                }
                Some(t)
            }
            "ARRAY" => {
                if !self.eat(&Token::Lt) {
                    return None;
                }
                let of = self.data_type()?;
                if !self.eat(&Token::Gt) {
                    return None;
                }
                Some(DataType {
                    name: "list".to_string(),
                    of: Some(Box::new(of)),
                    element_nullable: Some(true),
                    ..DataType::default()
                })
            }
            "MAP" => {
                if !self.eat(&Token::Lt) {
                    return None;
                }
                let key = self.data_type()?;
                if !self.eat(&Token::Comma) {
                    return None;
                }
                let value = self.data_type()?;
                if !self.eat(&Token::Gt) {
                    return None;
                }
                Some(DataType {
                    name: "map".to_string(),
                    key: Some(Box::new(key)),
                    of: Some(Box::new(value)),
                    element_nullable: Some(true),
                    ..DataType::default()
                })
            }
            "STRUCT" => {
                if !self.eat(&Token::Lt) {
                    return None;
                }
                let mut fields = Vec::new();
                loop {
                    let name = ident_of(self.peek()?, Case::Keep)?;
                    self.i += 1;
                    if !self.eat(&Token::Colon) {
                        return None;
                    }
                    let data_type = self.data_type()?;
                    let nullable = !(self.kw("NOT") && self.kw("NULL"));
                    let comment = if self.kw("COMMENT") {
                        let c = string_of(self.peek()?)?;
                        self.i += 1;
                        Some(c)
                    } else {
                        None
                    };
                    fields.push(StructField { field_id: 0, name, nullable, data_type, comment });
                    if self.eat(&Token::Gt) {
                        break;
                    }
                    if !self.eat(&Token::Comma) {
                        return None;
                    }
                }
                Some(DataType { name: "struct".to_string(), fields, ..DataType::default() })
            }
            _ => None,
        }
    }
}

/// Gives every nested field, list element and map key and value its field id, from `next`, the way Iceberg does:
/// a struct's fields first, then into each in turn.
pub fn assign_ids(t: &mut DataType, next: &mut i32) {
    t.assign_field_ids(next);
}

/// The type as Spark SQL writes it.
#[must_use]
pub fn write(t: &DataType) -> String {
    if t.is_verbatim() {
        return t.text.clone().unwrap_or_default();
    }
    let inner = |o: &Option<Box<DataType>>| o.as_deref().map(write).unwrap_or_default();
    match t.name.as_str() {
        "boolean" => "BOOLEAN".to_string(),
        "int" => "INT".to_string(),
        "long" => "BIGINT".to_string(),
        "float" => "FLOAT".to_string(),
        "double" => "DOUBLE".to_string(),
        "date" => "DATE".to_string(),
        "timestamptz" => "TIMESTAMP".to_string(),
        "timestamp" => "TIMESTAMP_NTZ".to_string(),
        "binary" => "BINARY".to_string(),
        "variant" => "VARIANT".to_string(),
        "string" => "STRING".to_string(),
        "decimal" => match (t.precision, t.scale) {
            (Some(p), Some(s)) => format!("DECIMAL({p},{s})"),
            (Some(p), None) => format!("DECIMAL({p})"),
            _ => "DECIMAL".to_string(),
        },
        "list" => format!("ARRAY<{}>", inner(&t.of)),
        "map" => format!("MAP<{}, {}>", inner(&t.key), inner(&t.of)),
        "struct" => {
            let fields: Vec<String> = t
                .fields
                .iter()
                .map(|f| {
                    let mut s = format!("`{}`: {}", f.name, write(&f.data_type));
                    if !f.nullable {
                        s.push_str(" NOT NULL");
                    }
                    if let Some(c) = &f.comment {
                        s.push_str(&format!(" COMMENT {}", quote(c)));
                    }
                    s
                })
                .collect();
            format!("STRUCT<{}>", fields.join(", "))
        }
        other => other.to_uppercase(),
    }
}

/// A Spark SQL string literal: `'…'`, with `\` and `'` escaped.
#[must_use]
pub fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\\', "\\\\").replace('\'', "\\'"))
}
