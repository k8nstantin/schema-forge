//! Cutting a dump into statements, each with its exact text and its tokens' positions in that text.
//!
//! Data never reaches the parser: `COPY … FROM stdin;` blocks (up to their `\.` line) are counted and left out.
//! Semicolons inside quoted strings, dollar-quoted bodies, comments and `BEGIN ATOMIC … END` bodies do not end a
//! statement.

use sqlparser::dialect::Dialect;
use sqlparser::keywords::Keyword;
use sqlparser::tokenizer::{Token, Tokenizer, Whitespace};

/// A token and where it sits in its statement's text (byte offsets).
#[derive(Debug, Clone, PartialEq)]
pub struct Tok {
    pub token: Token,
    pub start: usize,
    pub end: usize,
}

/// One statement: its exact text (no trailing `;`), its meaningful tokens, and the line it starts on.
#[derive(Debug, Clone)]
pub struct Statement {
    pub text: String,
    pub tokens: Vec<Tok>,
    pub line: usize,
    /// A psql meta-command (`\restrict …`): a line of its own, not SQL, never tokenized.
    pub meta: bool,
}

/// A dump cut into statements, and the data left out.
#[derive(Debug, Default)]
pub struct Split {
    pub statements: Vec<Statement>,
    /// `COPY … FROM stdin` blocks left out, and their rows.
    pub copy_blocks: usize,
    pub copy_rows: usize,
}

/// What stops a dump from being cut into statements.
#[derive(Debug, thiserror::Error)]
#[error("line {line}: {message}")]
pub struct SplitError {
    pub line: usize,
    pub message: String,
}

/// Cuts `text` into statements under `dialect`.
///
/// # Errors
/// When the text cannot be tokenized (an unterminated string or comment, …).
pub fn split(dialect: &dyn Dialect, text: &str) -> Result<Split, SplitError> {
    let mut out = Split::default();
    let mut segment_start = 0;
    let mut segment_line = 1;
    let lines: Vec<(usize, &str)> = line_offsets(text);
    let mut i = 0;
    while i < lines.len() {
        let (offset, line) = lines[i];
        if is_meta(line) {
            split_segment(dialect, &text[segment_start..offset], segment_line, &mut out)?;
            out.statements.push(Statement {
                text: line.trim_end().to_string(),
                tokens: Vec::new(),
                line: i + 1,
                meta: true,
            });
            i += 1;
            segment_start = lines.get(i).map_or(text.len(), |(o, _)| *o);
            segment_line = i + 1;
            continue;
        }
        if is_copy_from_stdin(line) {
            // The COPY statement itself is data too: everything up to it is one segment.
            split_segment(dialect, &text[segment_start..offset], segment_line, &mut out)?;
            out.copy_blocks += 1;
            i += 1;
            while i < lines.len() && lines[i].1.trim_end_matches('\r') != "\\." {
                out.copy_rows += 1;
                i += 1;
            }
            i += 1; // the `\.` line
            segment_start = lines.get(i).map_or(text.len(), |(o, _)| *o);
            segment_line = i + 1;
            continue;
        }
        i += 1;
    }
    split_segment(dialect, &text[segment_start..], segment_line, &mut out)?;
    Ok(out)
}

fn line_offsets(text: &str) -> Vec<(usize, &str)> {
    let mut out = Vec::new();
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        out.push((offset, line.trim_end_matches('\n')));
        offset += line.len();
    }
    out
}

/// A psql meta-command line: a backslash, then a command name.
fn is_meta(line: &str) -> bool {
    let mut chars = line.chars();
    chars.next() == Some('\\') && chars.next().is_some_and(|c| c.is_ascii_alphabetic())
}

fn is_copy_from_stdin(line: &str) -> bool {
    let l = line.trim_end();
    l.starts_with("COPY ") && l.ends_with("FROM stdin;")
}

/// Cuts one stretch of text with no data in it; `first_line` is its first line's number in the dump.
fn split_segment(dialect: &dyn Dialect, text: &str, first_line: usize, out: &mut Split) -> Result<(), SplitError> {
    if text.trim().is_empty() {
        return Ok(());
    }
    let tokens = Tokenizer::new(dialect, text).tokenize_with_location().map_err(|e| SplitError {
        line: first_line + usize::try_from(e.location.line).unwrap_or(1) - 1,
        message: e.message,
    })?;
    let starts = line_starts(text);
    let to_offset = |line: u64, column: u64| -> usize {
        let l = usize::try_from(line).unwrap_or(1).max(1) - 1;
        let line_start = starts.get(l).copied().unwrap_or(text.len());
        let col = usize::try_from(column).unwrap_or(1).max(1) - 1;
        text[line_start..].char_indices().nth(col).map_or(text.len(), |(b, _)| line_start + b)
    };

    let mut current: Vec<Tok> = Vec::new();
    let mut atomic_depth = 0usize;
    for t in tokens {
        let start = to_offset(t.span.start.line, t.span.start.column);
        let end = to_offset(t.span.end.line, t.span.end.column);
        match &t.token {
            Token::Whitespace(_) | Token::EOF => continue,
            Token::SemiColon if atomic_depth == 0 => {
                finish(text, &mut current, &starts, first_line, out);
                continue;
            }
            Token::Word(w) if w.keyword == Keyword::ATOMIC && is_word(current.last(), Keyword::BEGIN) => {
                atomic_depth += 1;
            }
            Token::Word(w) if w.keyword == Keyword::END && atomic_depth > 0 => atomic_depth -= 1,
            _ => {}
        }
        current.push(Tok { token: t.token, start, end });
    }
    finish(text, &mut current, &starts, first_line, out);
    Ok(())
}

fn is_word(t: Option<&Tok>, k: Keyword) -> bool {
    matches!(t, Some(Tok { token: Token::Word(w), .. }) if w.keyword == k)
}

fn line_starts(text: &str) -> Vec<usize> {
    let mut v = vec![0];
    v.extend(text.match_indices('\n').map(|(i, _)| i + 1));
    v
}

fn finish(text: &str, current: &mut Vec<Tok>, starts: &[usize], first_line: usize, out: &mut Split) {
    if current.is_empty() {
        return;
    }
    let start = current[0].start;
    let end = current.last().map_or(start, |t| t.end);
    let line = first_line + starts.partition_point(|s| *s <= start) - 1;
    let tokens = current.drain(..).map(|t| Tok { start: t.start - start, end: t.end - start, ..t }).collect();
    out.statements.push(Statement { text: text[start..end].to_string(), tokens, line, meta: false });
}

/// Whether a token is a comment (kept with the text, never parsed).
#[must_use]
pub fn is_comment(t: &Token) -> bool {
    matches!(t, Token::Whitespace(Whitespace::SingleLineComment { .. } | Whitespace::MultiLineComment(_)))
}

#[cfg(test)]
mod tests {
    use sqlparser::dialect::PostgreSqlDialect;

    use super::*;

    #[test]
    fn statements_are_cut_at_semicolons_outside_strings_bodies_and_data() {
        let dump = "\\restrict abc\nSET x = 1;\n-- a comment; with a semicolon\nCREATE TABLE t (a text DEFAULT 'a;b');\n\
                    COPY public.t (a) FROM stdin;\none\ntwo;three\n\\.\n\n\
                    CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END; $$;\n\
                    CREATE FUNCTION g() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END;\n\
                    COMMENT ON TABLE t IS 'it''s; fine'";
        let s = split(&PostgreSqlDialect {}, dump).expect("split");
        let texts: Vec<&str> = s.statements.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(
            texts,
            [
                "\\restrict abc",
                "SET x = 1",
                "CREATE TABLE t (a text DEFAULT 'a;b')",
                "CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END; $$",
                "CREATE FUNCTION g() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END",
                "COMMENT ON TABLE t IS 'it''s; fine'",
            ]
        );
        assert_eq!((s.copy_blocks, s.copy_rows), (1, 2));
        assert_eq!(s.statements.iter().map(|s| s.line).collect::<Vec<_>>(), [1, 2, 4, 10, 11, 12]);
        let create = &s.statements[2];
        let default = create.tokens.iter().find(|t| matches!(t.token, Token::SingleQuotedString(_))).expect("tok");
        assert_eq!(&create.text[default.start..default.end], "'a;b'");
    }
}
