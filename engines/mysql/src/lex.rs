//! A statement as tokens, read with `sqlparser`'s MySQL dialect, each token knowing where it is in the statement's
//! text: the reader walks the tokens to find the clauses, and takes expressions and bodies from the text exactly as
//! written.

use sqlparser::dialect::MySqlDialect;
use sqlparser::tokenizer::{Token, Tokenizer};

use crate::dump::mask_dollars;

/// A token and the bytes of the text it was read from.
#[derive(Debug, Clone, PartialEq)]
pub struct Tok {
    pub token: Token,
    pub start: usize,
    pub end: usize,
}

/// The tokens of one statement, and a place among them.
#[derive(Debug, Clone)]
pub struct Cursor<'a> {
    pub text: &'a str,
    toks: Vec<Tok>,
    at: usize,
}

impl<'a> Cursor<'a> {
    /// Reads `text` into tokens, leaving out spaces and comments.
    ///
    /// # Errors
    /// When the text is not MySQL's tokens (an unclosed quote).
    pub fn new(text: &'a str) -> Result<Self, String> {
        let masked = mask_dollars(text);
        let dialect = MySqlDialect {};
        let tokens = Tokenizer::new(&dialect, &masked).tokenize_with_location().map_err(|e| e.to_string())?;
        let starts: Vec<usize> =
            std::iter::once(0).chain(masked.match_indices('\n').map(|(i, _)| i + 1)).collect::<Vec<_>>();
        let offset = |line: u64, column: u64| -> usize {
            let Some(&from) = usize::try_from(line).ok().and_then(|l| starts.get(l.saturating_sub(1))) else {
                return masked.len();
            };
            let col = usize::try_from(column).unwrap_or(usize::MAX).saturating_sub(1);
            masked[from..].char_indices().nth(col).map_or(masked.len(), |(i, _)| from + i)
        };
        let toks = tokens
            .into_iter()
            .filter(|t| !matches!(t.token, Token::Whitespace(_) | Token::EOF))
            .map(|t| Tok {
                start: offset(t.span.start.line, t.span.start.column),
                end: offset(t.span.end.line, t.span.end.column),
                token: t.token,
            })
            .collect();
        Ok(Self { text, toks, at: 0 })
    }

    pub fn is_done(&self) -> bool {
        self.at >= self.toks.len()
    }

    pub fn peek(&self) -> Option<&Token> {
        self.toks.get(self.at).map(|t| &t.token)
    }

    pub fn peek_at(&self, ahead: usize) -> Option<&Token> {
        self.toks.get(self.at + ahead).map(|t| &t.token)
    }

    /// Where the cursor is, to come back to or to take the text from.
    pub fn mark(&self) -> usize {
        self.at
    }

    pub fn reset(&mut self, mark: usize) {
        self.at = mark;
    }

    pub fn next(&mut self) -> Option<&Token> {
        let t = self.toks.get(self.at).map(|t| &t.token);
        self.at += 1;
        t
    }

    /// Whether the next token is the unquoted word `word`, in any case.
    pub fn peek_kw(&self, word: &str) -> bool {
        self.peek_kw_at(0, word)
    }

    pub fn peek_kw_at(&self, ahead: usize, word: &str) -> bool {
        matches!(self.peek_at(ahead), Some(Token::Word(w)) if w.quote_style.is_none() && w.value.eq_ignore_ascii_case(word))
    }

    /// Takes the word `word` when it is next.
    pub fn eat_kw(&mut self, word: &str) -> bool {
        let yes = self.peek_kw(word);
        if yes {
            self.at += 1;
        }
        yes
    }

    /// Takes the words `words` when they are all next, in order.
    pub fn eat_kws(&mut self, words: &[&str]) -> bool {
        let yes = words.iter().enumerate().all(|(n, w)| self.peek_kw_at(n, w));
        if yes {
            self.at += words.len();
        }
        yes
    }

    /// The word `word`, or what is there instead.
    ///
    /// # Errors
    /// When the next token is not `word`.
    pub fn expect_kw(&mut self, word: &str) -> Result<(), String> {
        if self.eat_kw(word) { Ok(()) } else { Err(format!("expected {word}, found {}", self.here())) }
    }

    /// Takes `token` when it is next.
    pub fn eat(&mut self, token: &Token) -> bool {
        let yes = self.peek() == Some(token);
        if yes {
            self.at += 1;
        }
        yes
    }

    /// # Errors
    /// When the next token is not `token`.
    pub fn expect(&mut self, token: &Token) -> Result<(), String> {
        if self.eat(token) { Ok(()) } else { Err(format!("expected {token}, found {}", self.here())) }
    }

    /// A name, quoted or not.
    ///
    /// # Errors
    /// When the next token is not a name.
    pub fn name(&mut self) -> Result<String, String> {
        match self.peek() {
            Some(Token::Word(w)) => {
                let v = w.value.clone();
                self.at += 1;
                Ok(v)
            }
            _ => Err(format!("expected a name, found {}", self.here())),
        }
    }

    /// A name with the database it is in, when written (`shop.orders`).
    ///
    /// # Errors
    /// When the next token is not a name.
    pub fn qualified(&mut self) -> Result<(Option<String>, String), String> {
        let first = self.name()?;
        if self.eat(&Token::Period) { Ok((Some(first), self.name()?)) } else { Ok((None, first)) }
    }

    /// A quoted string's value.
    ///
    /// # Errors
    /// When the next token is not a string.
    pub fn string(&mut self) -> Result<String, String> {
        match self.peek() {
            Some(Token::SingleQuotedString(s) | Token::DoubleQuotedString(s)) => {
                let v = s.clone();
                self.at += 1;
                Ok(v)
            }
            _ => Err(format!("expected a string, found {}", self.here())),
        }
    }

    /// A whole number.
    ///
    /// # Errors
    /// When the next token is not one.
    pub fn number(&mut self) -> Result<i64, String> {
        match self.peek() {
            Some(Token::Number(n, _)) => {
                let v = n.parse::<i64>().map_err(|_| format!("`{n}` is not a whole number"))?;
                self.at += 1;
                Ok(v)
            }
            _ => Err(format!("expected a number, found {}", self.here())),
        }
    }

    /// The value of a `KEY [=] value` option, as written: a string's value, a word, a number.
    ///
    /// # Errors
    /// When nothing is there.
    pub fn value(&mut self) -> Result<String, String> {
        self.eat(&Token::Eq);
        match self.peek() {
            Some(Token::SingleQuotedString(s) | Token::DoubleQuotedString(s)) => {
                let v = s.clone();
                self.at += 1;
                Ok(v)
            }
            Some(Token::Word(w)) => {
                let v = w.value.clone();
                self.at += 1;
                Ok(v)
            }
            Some(Token::Number(n, _)) => {
                let v = n.clone();
                self.at += 1;
                Ok(v)
            }
            _ => Err(format!("expected a value, found {}", self.here())),
        }
    }

    /// The text inside the parentheses that open here, exactly as written, the cursor after them.
    ///
    /// # Errors
    /// When no parenthesis opens here, or it does not close.
    pub fn parens(&mut self) -> Result<&'a str, String> {
        let open = self.at;
        self.expect(&Token::LParen)?;
        let mut depth = 1;
        while let Some(t) = self.next() {
            match t {
                Token::LParen => depth += 1,
                Token::RParen => {
                    depth -= 1;
                    if depth == 0 {
                        let (from, to) = (self.toks[open].end, self.toks[self.at - 1].start);
                        return Ok(self.text[from..to].trim());
                    }
                }
                _ => {}
            }
        }
        Err("a parenthesis is not closed".to_string())
    }

    /// The text from the token at `from` up to the cursor, exactly as written.
    pub fn since(&self, from: usize) -> &'a str {
        if from >= self.at || from >= self.toks.len() {
            return "";
        }
        let end = self.toks[self.at.min(self.toks.len()) - 1].end;
        self.text[self.toks[from].start..end].trim()
    }

    /// The rest of the statement, exactly as written, the cursor at its end.
    pub fn rest(&mut self) -> &'a str {
        let from = self.toks.get(self.at).map_or(self.text.len(), |t| t.start);
        self.at = self.toks.len();
        self.text[from..].trim()
    }

    /// Moves on to the first of `words` at this depth of parentheses, or the end; true when one was found.
    pub fn skip_to_kw(&mut self, words: &[&str]) -> bool {
        let mut depth = 0;
        while let Some(t) = self.peek() {
            match t {
                Token::LParen => depth += 1,
                Token::RParen => depth -= 1,
                _ if depth == 0 && words.iter().any(|w| self.peek_kw(w)) => return true,
                _ => {}
            }
            self.at += 1;
        }
        false
    }

    /// How many tokens the statement has.
    pub fn len(&self) -> usize {
        self.toks.len()
    }

    /// Whether the token at `i` is `token`.
    pub fn is_token_at(&self, i: usize, token: &Token) -> bool {
        self.toks.get(i).is_some_and(|t| &t.token == token)
    }

    /// Whether the token at `i` is the unquoted word `word`.
    pub fn kw_at(&self, i: usize, word: &str) -> bool {
        matches!(self.toks.get(i).map(|t| &t.token), Some(Token::Word(w)) if w.quote_style.is_none() && w.value.eq_ignore_ascii_case(word))
    }

    /// The text from the token at `from` to the end of the token before `to`, exactly as written.
    pub fn slice(&self, from: usize, to: usize) -> &'a str {
        if from >= to || from >= self.toks.len() {
            return "";
        }
        self.text[self.toks[from].start..self.toks[to.min(self.toks.len()) - 1].end].trim()
    }

    /// What is next, as the reader is told it in an error.
    pub fn here(&self) -> String {
        self.peek().map_or("the end".to_string(), |t| format!("`{t}`"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_token_knows_its_place() {
        let text = "CREATE TABLE `t` (\n  a int DEFAULT (lower('x')),\n  ü varchar(2)\n) ENGINE=InnoDB";
        let mut c = Cursor::new(text).expect("tokens");
        assert!(c.eat_kws(&["create", "TABLE"]));
        assert_eq!(c.name().as_deref(), Ok("t"));
        assert_eq!(c.parens(), Ok("a int DEFAULT (lower('x')),\n  ü varchar(2)"));
        assert!(c.eat_kw("engine"));
        assert_eq!(c.value().as_deref(), Ok("InnoDB"));
        assert!(c.is_done());
    }

    #[test]
    fn the_text_between_marks_is_as_written() {
        let mut c = Cursor::new("SET a = 'x' , b=@@c").expect("tokens");
        c.next();
        let from = c.mark();
        c.skip_to_kw(&["nothing"]);
        assert_eq!(c.since(from), "a = 'x' , b=@@c");
        let mut c = Cursor::new("f() RETURNS int AS $$ it's; $$").expect("a dollar body tokenizes as one value");
        assert!(c.skip_to_kw(&["AS"]));
        assert_eq!(c.rest(), "AS $$ it's; $$", "taken from the text, not the masked tokens");
    }
}
