//! MySQL's column types as Arrow's: the one place engines meet. A type is read as `CAST(COLUMN_TYPE AS CHAR)` gives it
//! (`int unsigned`, `decimal(10,2)`, `enum('a','b')`), and every type maps, with how faithfully.

use arrow_schema::{DataType, TimeUnit};
use schema_forge_engine::{Fidelity, Mapped};

/// A type's base name, its arguments between the parentheses, and whether it is unsigned.
struct Parsed {
    base: String,
    arguments: String,
    unsigned: bool,
}

fn parse(column_type: &str) -> Parsed {
    let lower = column_type.trim().to_lowercase();
    let (base, rest) = match lower.find(['(', ' ']) {
        Some(at) => (lower[..at].to_string(), &lower[at..]),
        None => (lower.clone(), ""),
    };
    // The arguments are what the first parenthesis holds; an enum's values may hold parentheses, so the last one closes.
    let arguments = match (rest.find('('), rest.rfind(')')) {
        (Some(open), Some(close)) if close > open => rest[open + 1..close].to_string(),
        _ => String::new(),
    };
    Parsed {
        base,
        arguments,
        unsigned: lower.contains(" unsigned"),
    }
}

fn exact(data_type: DataType) -> Mapped {
    Mapped {
        data_type,
        fidelity: Fidelity::Exact,
    }
}

fn approximate(data_type: DataType, what: &str) -> Mapped {
    Mapped {
        data_type,
        fidelity: Fidelity::Approximate(what.to_string()),
    }
}

fn lost(data_type: DataType, what: &str) -> Mapped {
    Mapped {
        data_type,
        fidelity: Fidelity::Lost(what.to_string()),
    }
}

/// The two numbers of `decimal(p,s)`: precision and scale, MySQL's defaults (10, 0) where it names none.
fn precision_and_scale(arguments: &str) -> (u8, i8) {
    let mut numbers = arguments.split(',').map(|n| n.trim().parse::<u8>().ok());
    let precision = numbers.next().flatten().unwrap_or(10);
    let scale = numbers.next().flatten().unwrap_or(0);
    (precision, i8::try_from(scale).unwrap_or(0))
}

/// A MySQL column type as an Arrow type, with how faithful the mapping is.
#[must_use]
pub fn arrow_type(column_type: &str) -> Mapped {
    let p = parse(column_type);
    let unsigned = p.unsigned;
    match p.base.as_str() {
        "tinyint" | "bool" | "boolean" => exact(if unsigned { DataType::UInt8 } else { DataType::Int8 }),
        "smallint" => exact(if unsigned { DataType::UInt16 } else { DataType::Int16 }),
        "mediumint" => approximate(
            if unsigned { DataType::UInt32 } else { DataType::Int32 },
            "a 24-bit integer is held in 32 bits",
        ),
        "int" | "integer" => exact(if unsigned { DataType::UInt32 } else { DataType::Int32 }),
        "bigint" => exact(if unsigned { DataType::UInt64 } else { DataType::Int64 }),
        "decimal" | "numeric" | "dec" | "fixed" => {
            let (precision, scale) = precision_and_scale(&p.arguments);
            exact(if precision > 38 {
                DataType::Decimal256(precision, scale)
            } else {
                DataType::Decimal128(precision, scale)
            })
        }
        "float" => exact(DataType::Float32),
        "double" | "real" => exact(DataType::Float64),
        "char" | "varchar" | "tinytext" | "text" | "mediumtext" | "longtext" => {
            approximate(DataType::Utf8, "the length is not kept")
        }
        "binary" | "varbinary" | "tinyblob" | "blob" | "mediumblob" | "longblob" => {
            approximate(DataType::Binary, "the length is not kept")
        }
        "date" => exact(DataType::Date32),
        "datetime" => exact(DataType::Timestamp(TimeUnit::Microsecond, None)),
        "timestamp" => exact(DataType::Timestamp(TimeUnit::Microsecond, Some("UTC".into()))),
        "time" => approximate(
            DataType::Time64(TimeUnit::Microsecond),
            "a MySQL time may be negative or longer than a day",
        ),
        "year" => approximate(DataType::Int16, "the year is held as a number"),
        "json" => approximate(DataType::Utf8, "JSON is kept as text"),
        "enum" | "set" => approximate(DataType::Utf8, "the allowed values are not kept"),
        "bit" => approximate(DataType::UInt64, "the width of the bit field is not kept"),
        "geometry" | "point" | "linestring" | "polygon" | "multipoint" | "multilinestring" | "multipolygon"
        | "geometrycollection" | "geomcollection" => {
            lost(DataType::Binary, "the geometry's type and SRID are not kept")
        }
        other => lost(DataType::Binary, &format!("MySQL's type `{other}` has no Arrow type")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_type_of_the_samples_maps_to_an_arrow_type_with_its_fidelity() {
        let samples = [
            ("int", DataType::Int32, true),
            ("int unsigned", DataType::UInt32, true),
            ("bigint", DataType::Int64, true),
            ("bigint unsigned", DataType::UInt64, true),
            ("smallint", DataType::Int16, true),
            ("tinyint(1)", DataType::Int8, true),
            ("decimal(14,2)", DataType::Decimal128(14, 2), true),
            ("decimal(65,30)", DataType::Decimal256(65, 30), true),
            ("float", DataType::Float32, true),
            ("double", DataType::Float64, true),
            ("varchar(50)", DataType::Utf8, false),
            ("char(12)", DataType::Utf8, false),
            ("text", DataType::Utf8, false),
            ("binary(16)", DataType::Binary, false),
            ("blob", DataType::Binary, false),
            ("date", DataType::Date32, true),
            ("datetime(3)", DataType::Timestamp(TimeUnit::Microsecond, None), true),
            (
                "timestamp",
                DataType::Timestamp(TimeUnit::Microsecond, Some("UTC".into())),
                true,
            ),
            ("time(6)", DataType::Time64(TimeUnit::Microsecond), false),
            ("year", DataType::Int16, false),
            ("json", DataType::Utf8, false),
            ("enum('new','active','gone')", DataType::Utf8, false),
            ("set('vip','wholesale','test')", DataType::Utf8, false),
            ("bit(8)", DataType::UInt64, false),
        ];
        for (column_type, data_type, is_exact) in samples {
            let mapped = arrow_type(column_type);
            assert_eq!(mapped.data_type, data_type, "{column_type}");
            assert_eq!(mapped.fidelity == Fidelity::Exact, is_exact, "{column_type}");
        }
    }

    #[test]
    fn a_spatial_type_is_binary_and_lost() {
        let mapped = arrow_type("point");
        assert_eq!(mapped.data_type, DataType::Binary);
        assert!(matches!(mapped.fidelity, Fidelity::Lost(_)));
        assert!(matches!(arrow_type("geometry").fidelity, Fidelity::Lost(_)));
    }

    #[test]
    fn a_type_arrow_has_no_place_for_is_lost_naming_it() {
        match arrow_type("hyperloglog").fidelity {
            Fidelity::Lost(what) => assert!(what.contains("hyperloglog")),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn an_enums_values_may_hold_parentheses() {
        assert_eq!(arrow_type("enum('a(b)','c')").data_type, DataType::Utf8);
        assert_eq!(arrow_type("decimal").data_type, DataType::Decimal128(10, 0));
    }
}
