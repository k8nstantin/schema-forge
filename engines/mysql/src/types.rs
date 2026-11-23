//! MySQL's types, as one table: each family's name, the spellings MySQL accepts for it, the parameters it takes,
//! whether it may be `UNSIGNED`, its palette group, what it holds, a real example, and its versions. Reading a type is
//! the table walked, never a branch per type: a new type is a new row, and an add-on adds rows of its own.
//!
//! A column holds its type as MySQL writes it in lowercase: `int unsigned`, `varchar(200)`, `decimal(18,2)`,
//! `enum('new','paid')`. A column's charset and collation are its options, not its type.

use schema_forge_engine::{Parsed, TypeError, TypeGroup, TypeSpec};

use crate::versions::{self, VERSIONS};

pub const GROUPS: &[TypeGroup] = &[
    TypeGroup::new("whole", "Whole numbers"),
    TypeGroup::new("exact", "Exact decimals"),
    TypeGroup::new("approximate", "Approximate numbers"),
    TypeGroup::new("text", "Text"),
    TypeGroup::new("bytes", "Bytes"),
    TypeGroup::new("yes_no", "Yes or no"),
    TypeGroup::new("time", "Dates and times"),
    TypeGroup::new("lists", "Lists of values"),
    TypeGroup::new("json", "JSON"),
    TypeGroup::new("bits", "Bit strings"),
    TypeGroup::new("spatial", "Spatial"),
    TypeGroup::new("vectors", "Vectors"),
];

/// What a family takes in parentheses after its name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum Params {
    /// Nothing: `json`.
    None,
    /// A number, which the family needs: `varchar(200)`.
    One,
    /// A number or none, with the value it is when none is given: `char` is `char(1)`.
    OneOr(u32),
    /// A precision and a scale, or a precision, or none: `decimal(18,2)`.
    PrecisionScale,
    /// A display width, deprecated: kept as written when given, `int(11)`.
    Width,
    /// Digits of a second, written only when more than none: `datetime(6)`, and `datetime` for `datetime(0)`.
    Fraction,
    /// The values of an `enum` or a `set`, in order.
    Values,
}

/// One family of types: a row of the table. Made with [`Family::new`], so an add-on keeps building when it gains a
/// field.
#[derive(Debug, Clone, Copy)]
#[non_exhaustive]
pub struct Family {
    pub spec: TypeSpec,
    /// How a column writes it, before its parameters (`varchar`, `int`).
    pub base: &'static str,
    /// Every other spelling MySQL accepts for `base`, lowercase (`integer`, `character varying`).
    pub spellings: &'static [&'static str],
    pub params: Params,
    /// Whether it is this family when written `unsigned`.
    pub unsigned: bool,
}

impl Family {
    #[must_use]
    pub const fn new(base: &'static str, spellings: &'static [&'static str], params: Params, spec: TypeSpec) -> Self {
        Self { spec, base, spellings, params, unsigned: false }
    }

    /// The same family, written `unsigned`.
    #[must_use]
    pub const fn unsigned(self) -> Self {
        Self { unsigned: true, ..self }
    }
}

const fn t(name: &'static str, group: &'static str, meaning: &'static str, example: &'static str) -> TypeSpec {
    TypeSpec::new(name, group, meaning, example)
}

const fn whole(
    base: &'static str,
    spellings: &'static [&'static str],
    meaning: &'static str,
    umeaning: &'static str,
    uname: &'static str,
) -> [Family; 2] {
    [
        Family::new(base, spellings, Params::Width, t(base, "whole", meaning, base)),
        Family::new(base, spellings, Params::Width, t(uname, "whole", umeaning, uname)).unsigned(),
    ]
}

const TINYINT: [Family; 2] =
    whole("tinyint", &["int1"], "A whole number from -128 to 127", "A whole number from 0 to 255", "tinyint unsigned");
const SMALLINT: [Family; 2] = whole(
    "smallint",
    &["int2"],
    "A whole number from -32,768 to 32,767",
    "A whole number from 0 to 65,535",
    "smallint unsigned",
);
const MEDIUMINT: [Family; 2] = whole(
    "mediumint",
    &["int3", "middleint"],
    "A whole number from about -8.4 million to 8.4 million",
    "A whole number from 0 to about 16.8 million",
    "mediumint unsigned",
);
const INT: [Family; 2] = whole(
    "int",
    &["integer", "int4"],
    "A whole number up to about ±2.1 billion",
    "A whole number up to about 4.3 billion",
    "int unsigned",
);
const BIGINT: [Family; 2] = whole(
    "bigint",
    &["int8"],
    "A whole number up to about ±9.2 quintillion: ids, counts",
    "A whole number up to about 18.4 quintillion: ids",
    "bigint unsigned",
);

/// The families MySQL itself has, in palette order.
pub const BUILT_IN: &[Family] = &[
    TINYINT[0],
    TINYINT[1],
    SMALLINT[0],
    SMALLINT[1],
    MEDIUMINT[0],
    MEDIUMINT[1],
    INT[0],
    INT[1],
    BIGINT[0],
    BIGINT[1],
    Family::new(
        "decimal",
        &["dec", "numeric", "fixed"],
        Params::PrecisionScale,
        t("decimal(P,S)", "exact", "An exact number: P digits (up to 65), S after the point", "decimal(18,2)"),
    ),
    Family::new(
        "float",
        &[],
        Params::None,
        t("float", "approximate", "An approximate number, about 7 digits", "float"),
    ),
    Family::new(
        "double",
        &["real", "double precision"],
        Params::None,
        t("double", "approximate", "An approximate number, about 15 digits", "double"),
    ),
    Family::new(
        "char",
        &["character", "nchar", "national char"],
        Params::OneOr(1),
        t("char(N)", "text", "Text of exactly N characters", "char(8)"),
    ),
    Family::new(
        "varchar",
        &["character varying", "nvarchar", "national varchar"],
        Params::One,
        t("varchar(N)", "text", "Text up to N characters", "varchar(200)"),
    ),
    Family::new("tinytext", &[], Params::None, t("tinytext", "text", "Text up to 255 bytes", "tinytext")),
    Family::new("text", &[], Params::None, t("text", "text", "Text up to 64 KB", "text")),
    Family::new(
        "mediumtext",
        &["long varchar"],
        Params::None,
        t("mediumtext", "text", "Text up to 16 MB", "mediumtext"),
    ),
    Family::new("longtext", &[], Params::None, t("longtext", "text", "Text up to 4 GB", "longtext")),
    Family::new("binary", &[], Params::OneOr(1), t("binary(N)", "bytes", "Exactly N bytes", "binary(16)")),
    Family::new("varbinary", &[], Params::One, t("varbinary(N)", "bytes", "Up to N bytes", "varbinary(64)")),
    Family::new("tinyblob", &[], Params::None, t("tinyblob", "bytes", "Bytes up to 255", "tinyblob")),
    Family::new("blob", &[], Params::None, t("blob", "bytes", "Bytes up to 64 KB", "blob")),
    Family::new(
        "mediumblob",
        &["long varbinary"],
        Params::None,
        t("mediumblob", "bytes", "Bytes up to 16 MB", "mediumblob"),
    ),
    Family::new("longblob", &[], Params::None, t("longblob", "bytes", "Bytes up to 4 GB", "longblob")),
    Family::new("date", &[], Params::None, t("date", "time", "A calendar date", "date")),
    Family::new(
        "time",
        &[],
        Params::Fraction,
        t("time(P)", "time", "A time of day or a duration, to P digits of a second", "time(3)"),
    ),
    Family::new(
        "datetime",
        &[],
        Params::Fraction,
        t("datetime(P)", "time", "A date and time, no time zone, to P digits of a second", "datetime(6)"),
    ),
    Family::new(
        "timestamp",
        &[],
        Params::Fraction,
        t("timestamp(P)", "time", "A moment in time, stored in UTC, to P digits of a second", "timestamp(6)"),
    ),
    Family::new("year", &[], Params::None, t("year", "time", "A year, 1901 to 2155", "year")),
    Family::new(
        "enum",
        &[],
        Params::Values,
        t("enum(…)", "lists", "One of a list of values", "enum('new','active','closed')"),
    ),
    Family::new("set", &[], Params::Values, t("set(…)", "lists", "Any of a list of values", "set('vip','wholesale')")),
    Family::new("json", &[], Params::None, t("json", "json", "A JSON document, checked and stored parsed", "json")),
    Family::new("bit", &[], Params::OneOr(1), t("bit(N)", "bits", "Exactly N bits", "bit(8)")),
    Family::new("geometry", &[], Params::None, t("geometry", "spatial", "Any shape", "geometry")),
    Family::new("point", &[], Params::None, t("point", "spatial", "A point", "point")),
    Family::new("linestring", &[], Params::None, t("linestring", "spatial", "A line of points", "linestring")),
    Family::new("polygon", &[], Params::None, t("polygon", "spatial", "An area", "polygon")),
    Family::new("multipoint", &[], Params::None, t("multipoint", "spatial", "Points", "multipoint")),
    Family::new("multilinestring", &[], Params::None, t("multilinestring", "spatial", "Lines", "multilinestring")),
    Family::new("multipolygon", &[], Params::None, t("multipolygon", "spatial", "Areas", "multipolygon")),
    Family::new(
        "geomcollection",
        &["geometrycollection"],
        Params::None,
        t("geomcollection", "spatial", "Shapes of any kinds", "geomcollection"),
    ),
    Family::new(
        "vector",
        &[],
        Params::OneOr(2048),
        t("vector(N)", "vectors", "N numbers, for similarity search", "vector(8)")
            .available(versions::VECTOR.available),
    ),
];

/// `boolean` and `bool` are MySQL's `tinyint(1)`: a family of its own in the palette.
pub const BOOLEAN: TypeSpec = t("tinyint(1)", "yes_no", "True or false (MySQL's boolean)", "tinyint(1)");

/// The palette for `families`: the boolean among MySQL's own, then the add-ons'.
#[must_use]
pub fn catalog(families: &[Family]) -> Vec<TypeSpec> {
    let mut specs: Vec<TypeSpec> = families.iter().map(|f| f.spec).collect();
    let at = specs.iter().position(|s| s.group != "whole").unwrap_or(specs.len());
    specs.insert(at, BOOLEAN);
    specs
}

/// Reads a type as a column of a schema at `version` holds it.
///
/// # Errors
/// When it is not a MySQL type, or not one `version` has.
pub fn parse(families: &[Family], text: &str, version: &str) -> Result<Parsed, TypeError> {
    let not = |why: String| TypeError::NotAType(why);
    let raw = text.trim();
    let open = raw.find('(');
    let (head, args, tail) = match open {
        Some(o) => {
            let close = matching(raw, o).ok_or_else(|| not(format!("`{text}` has unbalanced parentheses")))?;
            (&raw[..o], Some(&raw[o + 1..close]), &raw[close + 1..])
        }
        None => (raw, None, ""),
    };
    // Without parentheses the attributes follow the name directly (`bigint unsigned`): the name is the words before
    // the first of them.
    let modifier = |w: &str| matches!(w.to_ascii_lowercase().as_str(), "unsigned" | "signed" | "zerofill");
    let words: Vec<&str> = head.split_whitespace().collect();
    let cut = words.iter().position(|w| modifier(w)).unwrap_or(words.len());
    let base = words[..cut].join(" ").to_ascii_lowercase();
    let mut unsigned = false;
    let mut zerofill = false;
    for w in words[cut..].iter().copied().chain(tail.split_whitespace()).map(str::to_ascii_lowercase) {
        match w.as_str() {
            "unsigned" => unsigned = true,
            "zerofill" => {
                zerofill = true;
                unsigned = true;
            }
            "signed" => {}
            _ => return Err(not(format!("`{text}`: `{w}` is not part of a type"))),
        }
    }
    if matches!(base.as_str(), "bool" | "boolean")
        || (base == "tinyint" && args.map(str::trim) == Some("1") && !unsigned)
    {
        return Ok(Parsed::new(BOOLEAN.name, BOOLEAN.example));
    }
    let fam = families
        .iter()
        .find(|f| (f.base == base || f.spellings.contains(&base.as_str())) && f.unsigned == unsigned)
        .or_else(|| {
            // UNSIGNED on a type that is never unsigned (FLOAT, DOUBLE, DECIMAL) is deprecated, and kept as written.
            families.iter().find(|f| (f.base == base || f.spellings.contains(&base.as_str())) && !f.unsigned)
        })
        .ok_or_else(|| not(format!("`{text}` is not a MySQL type")))?;
    let params = match (fam.params, args) {
        (Params::None, None) => String::new(),
        (Params::None, Some(a)) if matches!(fam.base, "float" | "double") => format!("({})", numbers(a, 2)?),
        // `TEXT(M)` and `BLOB(M)` are kept with their size: MySQL makes each the smallest type that holds M characters
        // of the column's character set, or M bytes, which only the server knows.
        (Params::None, Some(a)) if fam.base == "text" || fam.base == "blob" => format!("({})", numbers(a, 1)?),
        // `YEAR(4)` is MySQL's `year`; no other width is left.
        (Params::None, Some(a)) if fam.base == "year" && numbers(a, 1)? == "4" => String::new(),
        (Params::None, Some(_)) => return Err(not(format!("`{text}`: `{}` takes no size", fam.base))),
        (Params::One, Some(a)) => format!("({})", numbers(a, 1)?),
        (Params::One, None) => return Err(not(format!("`{text}`: `{}` needs a size", fam.base))),
        (Params::OneOr(_), Some(a)) | (Params::Width, Some(a)) => format!("({})", numbers(a, 1)?),
        (Params::OneOr(n), None) => format!("({n})"),
        (Params::Width, None) | (Params::Fraction, None) => String::new(),
        (Params::Fraction, Some(a)) => match numbers(a, 1)?.as_str() {
            "0" => String::new(),
            p => format!("({p})"),
        },
        (Params::PrecisionScale, Some(a)) => {
            let n = numbers(a, 2)?;
            if n.contains(',') { format!("({n})") } else { format!("({n},0)") }
        }
        (Params::PrecisionScale, None) => "(10,0)".to_string(),
        (Params::Values, Some(a)) => format!("({})", values(a).map_err(|why| not(format!("`{text}`: {why}")))?),
        (Params::Values, None) => return Err(not(format!("`{text}`: `{}` needs its values", fam.base))),
    };
    if !fam.spec.available.in_version(version, VERSIONS) {
        return Err(TypeError::not_in_version(fam.spec.name, fam.spec.available.since));
    }
    let mut out = format!("{}{params}", fam.base);
    if unsigned {
        out.push_str(" unsigned");
    }
    if zerofill {
        out.push_str(" zerofill");
    }
    Ok(Parsed::new(fam.spec.name, out))
}

/// Where the parenthesis opened at `open` closes, minding quoted values.
fn matching(s: &str, open: usize) -> Option<usize> {
    let mut depth = 0;
    let mut quote: Option<char> = None;
    let mut chars = s.char_indices().skip_while(|(i, _)| *i < open).peekable();
    while let Some((i, c)) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => {
                if chars.peek().is_some_and(|(_, n)| *n == q) {
                    chars.next();
                } else {
                    quote = None;
                }
            }
            (Some(_), '\\') => {
                chars.next();
            }
            (Some(_), _) => {}
            (None, '\'' | '"') => quote = Some(c),
            (None, '(') => depth += 1,
            (None, ')') => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
    }
    None
}

/// Up to `most` whole numbers, separated by commas, written without spaces.
fn numbers(args: &str, most: usize) -> Result<String, TypeError> {
    let parts: Vec<&str> = args.split(',').map(str::trim).collect();
    if parts.len() > most || parts.iter().any(|p| p.parse::<u32>().is_err()) {
        return Err(TypeError::NotAType(format!("({args}) is not the size it takes")));
    }
    Ok(parts.join(","))
}

/// An `enum` or `set` list, each value quoted with `'` and `'` inside doubled, separated by commas without spaces.
fn values(args: &str) -> Result<String, String> {
    let mut out = Vec::new();
    let mut chars = args.chars().peekable();
    loop {
        while chars.peek().is_some_and(|c| c.is_whitespace()) {
            chars.next();
        }
        let Some(q) = chars.next() else { break };
        if q != '\'' && q != '"' {
            return Err(format!("a value starts with `{q}`, not a quote"));
        }
        let mut v = String::new();
        loop {
            match chars.next() {
                None => return Err("a value is not closed".to_string()),
                // MySQL's escapes; `\%` and `\_` keep their backslash, any other escaped character is itself.
                Some('\\') => match chars.next() {
                    Some('0') => v.push('\0'),
                    Some('b') => v.push('\u{8}'),
                    Some('n') => v.push('\n'),
                    Some('r') => v.push('\r'),
                    Some('t') => v.push('\t'),
                    Some('Z') => v.push('\u{1a}'),
                    Some(c @ ('%' | '_')) => {
                        v.push('\\');
                        v.push(c);
                    }
                    Some(c) => v.push(c),
                    None => return Err("a value is not closed".to_string()),
                },
                Some(c) if c == q && chars.peek() == Some(&q) => {
                    chars.next();
                    v.push(q);
                }
                Some(c) if c == q => break,
                Some(c) => v.push(c),
            }
        }
        out.push(crate::write::string(&v));
        while chars.peek().is_some_and(|c| c.is_whitespace()) {
            chars.next();
        }
        match chars.next() {
            None => break,
            Some(',') => {}
            Some(c) => return Err(format!("`{c}` between values")),
        }
    }
    if out.is_empty() {
        return Err("it has no values".to_string());
    }
    Ok(out.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(t: &str) -> Result<String, String> {
        parse(BUILT_IN, t, "8.4").map(|p| p.text).map_err(|e| e.to_string())
    }

    #[test]
    fn what_a_dump_writes_reads_as_the_type() {
        assert_eq!(read("bigint unsigned").as_deref(), Ok("bigint unsigned"));
        assert_eq!(read("INT(10) UNSIGNED ZEROFILL").as_deref(), Ok("int(10) unsigned zerofill"));
        assert_eq!(read("tinyint(1)").as_deref(), Ok("tinyint(1)"));
        assert_eq!(read("boolean").as_deref(), Ok("tinyint(1)"));
        assert_eq!(read("decimal(18, 2)").as_deref(), Ok("decimal(18,2)"));
        assert_eq!(read("numeric").as_deref(), Ok("decimal(10,0)"));
        assert_eq!(read("char").as_deref(), Ok("char(1)"));
        assert_eq!(read("datetime").as_deref(), Ok("datetime"));
        assert_eq!(read("datetime(0)").as_deref(), Ok("datetime"), "as MySQL writes it");
        assert_eq!(read("timestamp(6)").as_deref(), Ok("timestamp(6)"));
        assert_eq!(read("integer").as_deref(), Ok("int"));
        assert_eq!(read("double precision").as_deref(), Ok("double"));
        assert_eq!(read("geometrycollection").as_deref(), Ok("geomcollection"));
        assert_eq!(read("float(7,4)").as_deref(), Ok("float(7,4)"), "deprecated, kept");
        assert_eq!(read("decimal(12,2) unsigned").as_deref(), Ok("decimal(12,2) unsigned"), "deprecated, kept");
        assert_eq!(read("text(100000)").as_deref(), Ok("text(100000)"), "the size is the server's to resolve");
        assert_eq!(read("BLOB(70000)").as_deref(), Ok("blob(70000)"));
        assert_eq!(read("year(4)").as_deref(), Ok("year"));
        assert!(read("year(2)").is_err(), "MySQL 8 has no two-digit year");
    }

    #[test]
    fn enum_and_set_values_are_kept_exactly() {
        assert_eq!(read("enum('new', 'active','it''s')").as_deref(), Ok("enum('new','active','it''s')"));
        assert_eq!(read("set(\"vip\",'wholesale')").as_deref(), Ok("set('vip','wholesale')"));
        assert_eq!(read("enum('A','a')").as_deref(), Ok("enum('A','a')"), "values keep their case");
        // As MySQL writes them, and so read back as themselves.
        assert_eq!(read(r"enum('a\\b','c\nd','it''s')").as_deref(), Ok(r"enum('a\\b','c\nd','it''s')"));
        assert_eq!(
            read(r"set('a\%','b\x')").as_deref(),
            Ok(r"set('a\\%','bx')"),
            "the same values, as MySQL reads them"
        );
        assert!(read("enum()").is_err());
    }

    #[test]
    fn vector_came_in_9_7() {
        assert_eq!(parse(BUILT_IN, "vector(8)", "9.7").map(|p| p.text), Ok("vector(8)".to_string()));
        assert_eq!(parse(BUILT_IN, "vector(8)", "8.4"), Err(TypeError::not_in_version("vector(N)", Some("9.7"))));
    }

    #[test]
    fn what_is_not_a_type_says_why() {
        assert!(read("varchar").is_err());
        assert!(read("json(5)").is_err());
        assert!(read("int unsigned purple").is_err());
        assert!(read("blobby").is_err());
    }
}
