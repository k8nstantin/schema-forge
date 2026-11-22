//! MySQL's types as Apache Arrow's, and back: how a MySQL schema meets every other engine and the DataFusion layer.
//! Each mapping says how faithful it is, and what it does not keep.

use schema_forge_engine::TypeError;
use schema_forge_engine::portable::{ArrowType, Mapped};

use crate::types::{self, BOOLEAN, Family};
use crate::versions;

/// Arrow's `TimeUnit`, from the engine interface's Arrow types.
type Unit = arrow_schema::TimeUnit;

/// A column's type as an Arrow type.
///
/// # Errors
/// When it is not one of MySQL's types in `version`.
pub fn arrow_type(families: &[Family], text: &str, version: &str) -> Result<Mapped<ArrowType>, TypeError> {
    use ArrowType as A;
    let parsed = types::parse(families, text, version)?;
    let t = parsed.text.as_str();
    let unsigned = t.contains(" unsigned");
    let numbers = params(t);
    let first = numbers.first().copied();
    let base = t.split(['(', ' ']).next().unwrap_or(t);
    let decorated = t.contains('(') || t.contains("zerofill");
    let whole = |signed: A, unsigned_type: A, name: &str| {
        let to = if unsigned { unsigned_type } else { signed };
        if decorated && parsed.family != BOOLEAN.name {
            Mapped::approximate(to, format!("the display width or ZEROFILL of `{name}`"))
        } else {
            Mapped::exact(to)
        }
    };
    Ok(match base {
        _ if parsed.family == BOOLEAN.name => Mapped::exact(A::Boolean),
        "tinyint" => whole(A::Int8, A::UInt8, t),
        "smallint" => whole(A::Int16, A::UInt16, t),
        "mediumint" => {
            let to = if unsigned { A::UInt32 } else { A::Int32 };
            Mapped::approximate(to, "the 24-bit range of `mediumint`")
        }
        "int" => whole(A::Int32, A::UInt32, t),
        "bigint" => whole(A::Int64, A::UInt64, t),
        "decimal" => {
            let (p, s) = (first.unwrap_or(10), numbers.get(1).copied().unwrap_or(0));
            let (p8, s8) = (u8::try_from(p).unwrap_or(u8::MAX), i8::try_from(s).unwrap_or(i8::MAX));
            let to = if p <= 38 { A::Decimal128(p8, s8) } else { A::Decimal256(p8, s8) };
            if unsigned { Mapped::approximate(to, "UNSIGNED on a decimal") } else { Mapped::exact(to) }
        }
        "float" if decorated => Mapped::approximate(A::Float32, "the precision and scale written after `float`"),
        "double" if decorated => Mapped::approximate(A::Float64, "the precision and scale written after `double`"),
        "float" => Mapped::exact(A::Float32),
        "double" => Mapped::exact(A::Float64),
        "char" | "varchar" => Mapped::approximate(A::Utf8, format!("the length {}", first.unwrap_or(1))),
        "tinytext" | "text" | "mediumtext" | "longtext" => {
            Mapped::approximate(A::Utf8, format!("the size limit of `{base}`"))
        }
        "binary" => {
            let n = i32::try_from(first.unwrap_or(1)).unwrap_or(i32::MAX);
            Mapped::exact(A::FixedSizeBinary(n))
        }
        "varbinary" => Mapped::approximate(A::Binary, format!("the length {}", first.unwrap_or(0))),
        "tinyblob" | "blob" | "mediumblob" | "longblob" => {
            Mapped::approximate(A::Binary, format!("the size limit of `{base}`"))
        }
        "date" => Mapped::exact(A::Date32),
        "time" => Mapped::approximate(
            A::Time64(Unit::Microsecond),
            "durations: a MySQL time runs from -838:59:59 to 838:59:59, an Arrow time within a day",
        ),
        "datetime" | "timestamp" => {
            let zone = (base == "timestamp").then(|| "UTC".into());
            match unit_of(first.unwrap_or(0)) {
                (unit, true) => Mapped::exact(A::Timestamp(unit, zone)),
                (unit, false) => {
                    Mapped::approximate(A::Timestamp(unit, zone), format!("the precision {}", first.unwrap_or(0)))
                }
            }
        }
        "year" => Mapped::approximate(A::Int16, "that it is a year from 1901 to 2155"),
        "enum" | "set" => Mapped::approximate(A::Utf8, format!("the values of the {base}")),
        "json" => Mapped::approximate(A::Utf8, "that it is JSON: Arrow has no JSON type"),
        "bit" => Mapped::approximate(A::Binary, format!("that it is {} bits", first.unwrap_or(1))),
        "geometry" | "point" | "linestring" | "polygon" | "multipoint" | "multilinestring" | "multipolygon"
        | "geomcollection" => Mapped::approximate(A::Binary, format!("that it is a {base}, held as well-known binary")),
        "vector" => {
            let n = i32::try_from(first.unwrap_or(2048)).unwrap_or(i32::MAX);
            Mapped::exact(A::new_fixed_size_list(A::Float32, n, true))
        }
        other => Mapped::lost(A::Utf8, format!("the type `{other}`, which an add-on brings: held as its text")),
    })
}

/// The MySQL type for an Arrow type, as a column of a schema at `version` holds it.
#[must_use]
pub fn engine_type(arrow: &ArrowType, version: &str) -> Mapped<String> {
    use ArrowType as A;
    let exact = |s: &str| Mapped::exact(s.to_string());
    let near = |s: &str, lost: &str| Mapped::approximate(s.to_string(), lost);
    match arrow {
        A::Boolean => exact(BOOLEAN.example),
        A::Int8 => exact("tinyint"),
        A::UInt8 => exact("tinyint unsigned"),
        A::Int16 => exact("smallint"),
        A::UInt16 => exact("smallint unsigned"),
        A::Int32 => exact("int"),
        A::UInt32 => exact("int unsigned"),
        A::Int64 => exact("bigint"),
        A::UInt64 => exact("bigint unsigned"),
        A::Float16 => near("float", "half precision: held as a float"),
        A::Float32 => exact("float"),
        A::Float64 => exact("double"),
        A::Decimal32(p, s) | A::Decimal64(p, s) | A::Decimal128(p, s) | A::Decimal256(p, s) => {
            let (p, s) = (u32::from(*p), u32::try_from(*s).unwrap_or(0));
            if p <= 65 && s <= 30 {
                Mapped::exact(format!("decimal({p},{s})"))
            } else {
                Mapped::lost(format!("decimal(65,{})", s.min(30)), format!("the precision {p} and scale {s}"))
            }
        }
        A::Utf8 | A::LargeUtf8 | A::Utf8View => near("longtext", "text over 4 GB"),
        A::Binary | A::LargeBinary | A::BinaryView => near("longblob", "bytes over 4 GB"),
        A::FixedSizeBinary(n) if (1..=255).contains(n) => Mapped::exact(format!("binary({n})")),
        A::FixedSizeBinary(n) => near("longblob", &format!("the fixed length {n}")),
        A::Date32 => exact("date"),
        A::Date64 => near("date", "the milliseconds of the day"),
        A::Time32(unit) | A::Time64(unit) => {
            let (p, lost) = precision_of(*unit);
            let t = if p == 0 { "time".to_string() } else { format!("time({p})") };
            lost.map_or_else(|| Mapped::exact(t.clone()), |l| Mapped::approximate(t.clone(), l))
        }
        A::Timestamp(unit, zone) => {
            let (p, lost) = precision_of(*unit);
            let base = if zone.is_some() { "timestamp" } else { "datetime" };
            let t = if p == 0 { base.to_string() } else { format!("{base}({p})") };
            match (lost, zone.as_deref()) {
                (Some(l), _) => Mapped::approximate(t, l),
                (None, Some(z)) if z != "UTC" && z != "+00:00" => {
                    Mapped::approximate(t, format!("the time zone {z}: MySQL keeps a timestamp in UTC"))
                }
                _ => Mapped::exact(t),
            }
        }
        A::Duration(_) | A::Interval(_) => near("time(6)", "durations longer than 838 hours"),
        A::FixedSizeList(field, n) if *field.data_type() == A::Float32 && versions::has(version, &versions::VECTOR) => {
            Mapped::exact(format!("vector({n})"))
        }
        other => Mapped::lost("json".to_string(), format!("the type {other}: held as JSON")),
    }
}

/// The numbers in a type's parentheses (`decimal(18,2)` is 18 and 2); none for an `enum` or a `set`.
fn params(t: &str) -> Vec<u32> {
    if t.starts_with("enum") || t.starts_with("set") {
        return Vec::new();
    }
    t.split_once('(')
        .and_then(|(_, rest)| rest.split_once(')'))
        .map(|(inside, _)| inside.split(',').filter_map(|n| n.trim().parse().ok()).collect())
        .unwrap_or_default()
}

/// The Arrow unit for `p` digits of a second, and whether it holds exactly `p` digits.
fn unit_of(p: u32) -> (Unit, bool) {
    match p {
        0 => (Unit::Second, true),
        1..=3 => (Unit::Millisecond, p == 3),
        _ => (Unit::Microsecond, p == 6),
    }
}

/// The digits of a second for an Arrow unit, and what MySQL does not keep of it.
fn precision_of(unit: Unit) -> (u32, Option<&'static str>) {
    match unit {
        Unit::Second => (0, None),
        Unit::Millisecond => (3, None),
        Unit::Microsecond => (6, None),
        Unit::Nanosecond => (6, Some("nanoseconds: MySQL keeps microseconds")),
    }
}
