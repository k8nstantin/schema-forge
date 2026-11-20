//! Walking a statement's tokens, with the exact source text of any stretch of them.

use sqlparser::tokenizer::Token;

use crate::split::{Statement, Tok};

/// How a dialect spells names: PostgreSQL folds unquoted names to lowercase; MySQL keeps them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Case {
    FoldLower,
    Keep,
}

/// A position in a statement's tokens.
pub struct Cur<'a> {
    pub st: &'a Statement,
    pub i: usize,
    pub case: Case,
}

impl<'a> Cur<'a> {
    pub fn new(st: &'a Statement, case: Case) -> Self {
        Self { st, i: 0, case }
    }

    pub fn toks(&self) -> &'a [Tok] {
        &self.st.tokens
    }

    pub fn at_end(&self) -> bool {
        self.i >= self.st.tokens.len()
    }

    pub fn peek(&self) -> Option<&'a Tok> {
        self.st.tokens.get(self.i)
    }

    pub fn peek_at(&self, n: usize) -> Option<&'a Tok> {
        self.st.tokens.get(self.i + n)
    }

    pub fn bump(&mut self) -> Option<&'a Tok> {
        let t = self.st.tokens.get(self.i);
        self.i += 1;
        t
    }

    /// Whether the token `n` ahead is the unquoted word `kw`.
    pub fn is_kw_at(&self, n: usize, kw: &str) -> bool {
        self.peek_at(n).is_some_and(|t| is_kw(&t.token, kw))
    }

    pub fn is_kw(&self, kw: &str) -> bool {
        self.is_kw_at(0, kw)
    }

    /// Eats the word `kw` if it is next.
    pub fn kw(&mut self, kw: &str) -> bool {
        if self.is_kw(kw) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    /// Eats the words `kws` if they are next, in order; otherwise eats nothing.
    pub fn kws(&mut self, kws: &[&str]) -> bool {
        if kws.iter().enumerate().all(|(n, k)| self.is_kw_at(n, k)) {
            self.i += kws.len();
            true
        } else {
            false
        }
    }

    pub fn is(&self, t: &Token) -> bool {
        self.peek().is_some_and(|x| &x.token == t)
    }

    pub fn eat(&mut self, t: &Token) -> bool {
        if self.is(t) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    /// An identifier: a quoted name as written, an unquoted one folded as the dialect folds it.
    pub fn ident(&mut self) -> Option<String> {
        let t = self.peek()?;
        let name = ident_of(&t.token, self.case)?;
        self.i += 1;
        Some(name)
    }

    /// A dotted name: `name`, `schema.name`, `catalog.schema.name`.
    pub fn qualified(&mut self) -> Option<Vec<String>> {
        let mut parts = vec![self.ident()?];
        while self.is(&Token::Period) {
            self.i += 1;
            parts.push(self.ident()?);
        }
        Some(parts)
    }

    /// The exact source from token `from` up to, not including, token `to`.
    pub fn text(&self, from: usize, to: usize) -> &'a str {
        let toks = &self.st.tokens;
        if from >= to || from >= toks.len() {
            return "";
        }
        let end = toks[to.min(toks.len()) - 1].end;
        &self.st.text[toks[from].start..end]
    }

    /// From the current token to the end of the statement.
    pub fn rest(&self) -> &'a str {
        self.text(self.i, self.st.tokens.len())
    }

    /// With the cursor on `(`, the index of its matching `)`.
    pub fn matching(&self, open: usize) -> Option<usize> {
        let mut depth = 0usize;
        for (n, t) in self.st.tokens.iter().enumerate().skip(open) {
            match t.token {
                Token::LParen => depth += 1,
                Token::RParen => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(n);
                    }
                }
                _ => {}
            }
        }
        None
    }

    /// With the cursor on `(`: the indexes inside it, and moves past the `)`.
    pub fn group(&mut self) -> Option<(usize, usize)> {
        if !self.is(&Token::LParen) {
            return None;
        }
        let close = self.matching(self.i)?;
        let inside = (self.i + 1, close);
        self.i = close + 1;
        Some(inside)
    }

    /// Splits tokens `from..to` at commas outside parentheses.
    pub fn commas(&self, from: usize, to: usize) -> Vec<(usize, usize)> {
        let mut out = Vec::new();
        let mut depth = 0i32;
        let mut start = from;
        for (n, tok) in self.st.tokens.iter().enumerate().take(to).skip(from) {
            match tok.token {
                Token::LParen | Token::LBracket => depth += 1,
                Token::RParen | Token::RBracket => depth -= 1,
                Token::Comma if depth == 0 => {
                    out.push((start, n));
                    start = n + 1;
                }
                _ => {}
            }
        }
        if start < to {
            out.push((start, to));
        }
        out
    }

    /// The first index in `from..to`, outside parentheses, whose token `stop` accepts.
    pub fn find_top(&self, from: usize, to: usize, stop: impl Fn(&Token) -> bool) -> usize {
        let mut depth = 0i32;
        for (n, tok) in self.st.tokens.iter().enumerate().take(to).skip(from) {
            let t = &tok.token;
            match t {
                Token::LParen | Token::LBracket => depth += 1,
                Token::RParen | Token::RBracket => depth -= 1,
                _ if depth == 0 && stop(t) => return n,
                _ => {}
            }
        }
        to
    }
}

/// Whether `t` is the unquoted word `kw` (any case).
pub fn is_kw(t: &Token, kw: &str) -> bool {
    matches!(t, Token::Word(w) if w.quote_style.is_none() && w.value.eq_ignore_ascii_case(kw))
}

/// The identifier a token names, folded as `case` says when unquoted.
pub fn ident_of(t: &Token, case: Case) -> Option<String> {
    match t {
        Token::Word(w) if w.quote_style.is_some() => Some(w.value.clone()),
        Token::Word(w) => Some(match case {
            Case::FoldLower => w.value.to_lowercase(),
            Case::Keep => w.value.clone(),
        }),
        _ => None,
    }
}

/// The text of a string literal token.
pub fn string_of(t: &Token) -> Option<String> {
    match t {
        Token::SingleQuotedString(s) | Token::EscapedStringLiteral(s) | Token::NationalStringLiteral(s) => {
            Some(s.clone())
        }
        _ => None,
    }
}
