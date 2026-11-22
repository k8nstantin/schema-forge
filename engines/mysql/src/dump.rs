//! A MySQL script cut into statements, the way the `mysql` client cuts it: versioned comments (`/*!50003 … */`) read as
//! the code they hold, `DELIMITER` changing what ends a statement, and quotes, comments and dollar-quoted bodies never
//! ending one. Everything keeps its place in the file, so a statement's line is the line it is on.

/// One statement: its text, without the delimiter that ended it, and the line it starts on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Statement {
    pub text: String,
    pub line: usize,
}

/// The script with every versioned comment opened: its markers (`/*!50003` and the `*/` that closes it) become
/// spaces, so the code inside reads as code and every other byte stays where it was.
#[must_use]
pub fn unwrap(sql: &str) -> String {
    let b = sql.as_bytes();
    let mut out = b.to_vec();
    let mut i = 0;
    let mut in_versioned = false;
    while i < b.len() {
        match b[i] {
            q @ (b'\'' | b'"' | b'`') => i = skip_quoted(b, i, q),
            b'*' if in_versioned && b.get(i + 1) == Some(&b'/') => {
                out[i] = b' ';
                out[i + 1] = b' ';
                in_versioned = false;
                i += 2;
            }
            b'/' if b.get(i + 1) == Some(&b'*') => {
                if !in_versioned && b.get(i + 2) == Some(&b'!') {
                    let mut j = i + 3;
                    while j < b.len() && b[j].is_ascii_digit() {
                        j += 1;
                    }
                    out[i..j].fill(b' ');
                    in_versioned = true;
                    i = j;
                } else {
                    i = skip_block_comment(b, i);
                }
            }
            b'-' if is_dash_comment(b, i) => i = skip_line(b, i),
            b'#' => i = skip_line(b, i),
            _ => i += 1,
        }
    }
    // Only ASCII bytes were replaced by ASCII spaces: the text is as valid as it was.
    String::from_utf8(out).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
}

/// The statements of an opened script ([`unwrap`]), in order. `DELIMITER` lines are the client's, not statements.
#[must_use]
pub fn statements(text: &str) -> Vec<Statement> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut delimiter = b";".to_vec();
    let mut code_at: Option<usize> = None;
    let mut i = 0;
    let line_of = |at: usize| text[..at].bytes().filter(|&c| c == b'\n').count() + 1;
    while i < b.len() {
        if code_at.is_none() && at_line_start(b, i) && starts_word(b, i, b"delimiter") {
            let end = b[i..].iter().position(|&c| c == b'\n').map_or(b.len(), |n| i + n);
            let d = text[i + "delimiter".len()..end].trim();
            if !d.is_empty() {
                delimiter = d.as_bytes().to_vec();
            }
            i = end;
            continue;
        }
        if b[i..].starts_with(&delimiter) {
            if let Some(at) = code_at {
                out.push(Statement { text: text[at..i].trim_end().to_string(), line: line_of(at) });
            }
            i += delimiter.len();
            code_at = None;
            continue;
        }
        let next = match b[i] {
            q @ (b'\'' | b'"' | b'`') => skip_quoted(b, i, q),
            b'$' if dollar_tag(b, i).is_some() => skip_dollar(b, i),
            b'/' if b.get(i + 1) == Some(&b'*') => {
                i = skip_block_comment(b, i);
                continue;
            }
            b'-' if is_dash_comment(b, i) => {
                i = skip_line(b, i);
                continue;
            }
            b'#' => {
                i = skip_line(b, i);
                continue;
            }
            c if c.is_ascii_whitespace() => {
                i += 1;
                continue;
            }
            _ => i + 1,
        };
        code_at.get_or_insert(i);
        i = next;
    }
    if let Some(at) = code_at {
        out.push(Statement { text: text[at..].trim_end().to_string(), line: line_of(at) });
    }
    out
}

/// The text with every dollar-quoted body (`$$ … $$`, `$js$ … $js$`) turned into a quoted string of the same length,
/// so a tokenizer reads it as one value whatever it holds, and every other byte stays where it was.
#[must_use]
pub fn mask_dollars(text: &str) -> String {
    let b = text.as_bytes();
    let mut out = b.to_vec();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            q @ (b'\'' | b'"' | b'`') => i = skip_quoted(b, i, q),
            b'$' if dollar_tag(b, i).is_some() => {
                let end = skip_dollar(b, i);
                for (k, byte) in out.iter_mut().enumerate().take(end).skip(i) {
                    if *byte != b'\n' {
                        *byte = if k == i || k + 1 == end { b'\'' } else { b' ' };
                    }
                }
                i = end;
            }
            b'/' if b.get(i + 1) == Some(&b'*') => i = skip_block_comment(b, i),
            b'-' if is_dash_comment(b, i) => i = skip_line(b, i),
            b'#' => i = skip_line(b, i),
            _ => i += 1,
        }
    }
    String::from_utf8(out).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
}

/// Past the quoted text opening at `i` with `q`: a doubled quote stays inside, and in `'` and `"` a backslash escapes
/// the next character, as MySQL reads them by default.
fn skip_quoted(b: &[u8], i: usize, q: u8) -> usize {
    let mut j = i + 1;
    while j < b.len() {
        if b[j] == b'\\' && q != b'`' {
            j += 2;
        } else if b[j] == q {
            if b.get(j + 1) == Some(&q) {
                j += 2;
            } else {
                return j + 1;
            }
        } else {
            j += 1;
        }
    }
    b.len()
}

fn skip_block_comment(b: &[u8], i: usize) -> usize {
    b[i + 2..].windows(2).position(|w| w == b"*/").map_or(b.len(), |n| i + 2 + n + 2)
}

fn skip_line(b: &[u8], i: usize) -> usize {
    b[i..].iter().position(|&c| c == b'\n').map_or(b.len(), |n| i + n)
}

/// `--` starts a comment only when a space, a control character or the end follows it.
fn is_dash_comment(b: &[u8], i: usize) -> bool {
    b.get(i + 1) == Some(&b'-') && b.get(i + 2).is_none_or(|c| c.is_ascii_whitespace() || c.is_ascii_control())
}

/// The tag of a dollar quote opening at `i` (`$$` or `$tag$`), when one does: not inside a name like `a$b`.
fn dollar_tag(b: &[u8], i: usize) -> Option<&[u8]> {
    if i > 0 && (b[i - 1].is_ascii_alphanumeric() || b[i - 1] == b'_' || b[i - 1] == b'$') {
        return None;
    }
    let mut j = i + 1;
    while j < b.len() && (b[j].is_ascii_alphabetic() || b[j] == b'_') {
        j += 1;
    }
    (b.get(j) == Some(&b'$')).then(|| &b[i..=j])
}

fn skip_dollar(b: &[u8], i: usize) -> usize {
    let Some(tag) = dollar_tag(b, i) else { return i + 1 };
    let from = i + tag.len();
    b[from..].windows(tag.len()).position(|w| w == tag).map_or(b.len(), |n| from + n + tag.len())
}

fn at_line_start(b: &[u8], i: usize) -> bool {
    b[..i].iter().rev().take_while(|&&c| c != b'\n').all(u8::is_ascii_whitespace)
}

fn starts_word(b: &[u8], i: usize, word: &[u8]) -> bool {
    b.len() >= i + word.len()
        && b[i..i + word.len()].eq_ignore_ascii_case(word)
        && b.get(i + word.len()).is_none_or(u8::is_ascii_whitespace)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(sql: &str) -> Vec<String> {
        statements(&unwrap(sql)).into_iter().map(|s| s.text).collect()
    }

    #[test]
    fn versioned_comments_read_as_their_code_and_keep_every_place() {
        let sql = "/*!40101 SET NAMES utf8 */;\nCREATE TABLE t (a int) /*!50100 PARTITION BY HASH (a) */;";
        let open = unwrap(sql);
        assert_eq!(open.len(), sql.len());
        assert_eq!(
            texts(sql),
            ["SET NAMES utf8".to_string(), format!("CREATE TABLE t (a int) {}PARTITION BY HASH (a)", " ".repeat(9))]
        );
        assert_eq!(unwrap("/* plain */ x"), "/* plain */ x", "a plain comment stays a comment");
        assert_eq!(unwrap("SELECT '/*!50003 no */'"), "SELECT '/*!50003 no */'", "nor inside a string");
    }

    #[test]
    fn delimiter_changes_what_ends_a_statement() {
        let sql = "DELIMITER ;;\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END ;;\nDELIMITER ;\nSELECT 3;";
        assert_eq!(texts(sql), ["CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "SELECT 3"]);
    }

    #[test]
    fn quotes_and_comments_never_end_a_statement() {
        let sql = "SELECT 'a;b', \"c;d\", `e;f`, 'it''s;', 'x\\';y' -- no; end\n, 1 # nor;\n/* nor ; */;";
        let s = statements(&unwrap(sql));
        assert_eq!(s.len(), 1);
        assert!(s[0].text.ends_with("/* nor ; */"));
        assert_eq!(texts("--\n-- only comments\n--\n"), Vec::<String>::new());
    }

    #[test]
    fn a_statement_knows_its_line() {
        let s = statements(&unwrap("-- header\n\nSELECT 1;\n\n  SELECT\n 2;"));
        assert_eq!(s.iter().map(|s| s.line).collect::<Vec<_>>(), [3, 5]);
    }

    #[test]
    fn dollar_quoted_bodies_hold_anything() {
        let sql = "CREATE FUNCTION f() RETURNS int LANGUAGE JAVASCRIPT AS $$ return 1; // it's \"fine\" $$;\nSELECT 1;";
        let s = texts(sql);
        assert_eq!(s.len(), 2);
        assert!(s[0].ends_with("$$"));
        let masked = mask_dollars(&s[0]);
        assert_eq!(masked.len(), s[0].len());
        assert!(masked.ends_with('\'') && !masked.contains("return"));
        assert_eq!(texts("SELECT a$b; SELECT 2"), ["SELECT a$b", "SELECT 2"], "a `$` in a name is not a quote");
    }
}
