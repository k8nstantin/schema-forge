//! How each type of one target lands in another: one map per pair, read by the compatibility rules and, later, by
//! conversion between targets, so a check and a conversion never disagree (docs/rules.md, Compatibility).

use serde::Serialize;

use crate::{DataType, Target};

/// How a type lands in the other target.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Grade {
    /// Unchanged.
    Exact,
    /// Bigger, and safe: every value fits.
    Widened,
    /// There is a choice to make (a length, one of two types).
    Decide,
    /// It fits, but something is lost.
    Lossy,
    /// The other target has no type for it.
    None,
}

/// One line of a map: the types it covers on each side, its grade and why.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct MapRow {
    pub from: &'static str,
    pub to: &'static str,
    pub grade: Grade,
    pub why: &'static str,
}

/// The map for one pair of targets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct TypeMap {
    pub id: &'static str,
    pub from: Target,
    pub to: Target,
    pub rows: &'static [MapRow],
}

const fn row(from: &'static str, to: &'static str, grade: Grade, why: &'static str) -> MapRow {
    MapRow { from, to, grade, why }
}

use Grade::{Decide, Exact, Lossy, Widened};

const ICEBERG_MYSQL: &[MapRow] = &[
    row("boolean", "BOOLEAN (tinyint(1))", Exact, ""),
    row("int", "INT", Exact, ""),
    row("long", "BIGINT", Exact, ""),
    row("float, double", "FLOAT, DOUBLE", Exact, ""),
    row("decimal(p,s)", "DECIMAL(p,s)", Exact, "Iceberg stops at 38 digits, MySQL at 65."),
    row("date", "DATE", Exact, ""),
    row("time", "TIME(6)", Exact, ""),
    row("timestamp", "DATETIME(6)", Exact, ""),
    row(
        "timestamptz",
        "DATETIME(6), stored as UTC",
        Lossy,
        "MySQL keeps no zone; TIMESTAMP keeps UTC but only covers 1970–2038.",
    ),
    row(
        "string",
        "VARCHAR(n) or TEXT",
        Decide,
        "TEXT holds anything, but a key or an index needs VARCHAR(n): choose a length.",
    ),
    row("uuid", "BINARY(16) or CHAR(36)", Decide, "MySQL has no uuid type: BINARY(16) is compact, CHAR(36) readable."),
    row("binary, fixed(L)", "LONGBLOB, BINARY(L)", Exact, ""),
    row(
        "struct",
        "JSON, or columns flattened",
        Lossy,
        "In JSON the fields lose their types and Iceberg field ids; flattened, they keep them.",
    ),
    row("list", "JSON, or a child table", Lossy, "MySQL has no array type."),
    row("map", "JSON", Lossy, "Keys and values lose their types."),
    row("timestamp_ns, timestamptz_ns", "DATETIME(6)", Lossy, "MySQL keeps microseconds, not nanoseconds."),
    row("variant", "JSON", Lossy, "Typed values (dates, decimals) become plain JSON."),
    row("geometry, geography", "GEOMETRY", Decide, "Choose the spatial reference (SRID) MySQL stores."),
    row(
        "list<struct>",
        "a child table, or JSON",
        Lossy,
        "A child table keeps the types and can be queried; JSON cannot be indexed.",
    ),
];

const ICEBERG_POSTGRES: &[MapRow] = &[
    row("boolean", "boolean", Exact, ""),
    row("int, long", "integer, bigint", Exact, ""),
    row("float, double", "real, double precision", Exact, ""),
    row("decimal(p,s)", "numeric(p,s)", Exact, ""),
    row("date, time", "date, time", Exact, ""),
    row("timestamp, timestamptz", "timestamp, timestamptz", Exact, ""),
    row("string", "text", Exact, ""),
    row("uuid", "uuid", Exact, ""),
    row("binary", "bytea", Exact, ""),
    row("fixed(L)", "bytea", Widened, "The fixed length is not kept."),
    row("list of a simple type", "an array (real[], text[])", Exact, ""),
    row(
        "struct",
        "a composite type, or jsonb",
        Decide,
        "A composite type keeps the field types but must be created first.",
    ),
    row("list<struct>", "a composite array, or a child table", Decide, ""),
    row("map", "jsonb", Lossy, "Keys and values lose their types."),
    row(
        "timestamp_ns, timestamptz_ns",
        "timestamp, timestamptz",
        Lossy,
        "PostgreSQL keeps microseconds, not nanoseconds.",
    ),
    row("variant", "jsonb", Lossy, "Typed values (dates, decimals) become plain JSON."),
    row("geometry, geography", "PostGIS geometry, geography", Decide, "Needs the PostGIS extension."),
];

const MYSQL_ICEBERG: &[MapRow] = &[
    row("tinyint, smallint, mediumint", "int", Widened, ""),
    row("int", "int", Exact, ""),
    row("int unsigned", "long", Widened, ""),
    row("bigint", "long", Exact, ""),
    row("bigint unsigned", "decimal(20,0)", Widened, "Too big for long."),
    row("decimal(p,s), p ≤ 38", "decimal(p,s)", Exact, ""),
    row(
        "decimal(p,s), p > 38",
        "no type",
        Grade::None,
        "Iceberg decimals stop at 38 digits: narrow it, or keep it as a string.",
    ),
    row("float, double", "float, double", Exact, ""),
    row("char, varchar, text", "string", Widened, "The length limit is not kept."),
    row("enum, set", "string", Lossy, "The allowed values are not kept: keep them as a rule."),
    row("date", "date", Exact, "A zero date (0000-00-00) has no value and arrives as null."),
    row("datetime", "timestamp", Exact, ""),
    row("timestamp", "timestamptz", Exact, ""),
    row("time", "time", Lossy, "MySQL time runs to ±838 hours; Iceberg time is a time of day."),
    row("year", "int", Widened, ""),
    row("json", "string (variant in format 3)", Lossy, ""),
    row("bit", "boolean, binary", Exact, ""),
    row("binary, varbinary, blob", "binary", Exact, ""),
    row("boolean", "boolean", Exact, ""),
    row("geometry and the other spatial types", "geometry (format 3), or binary", Decide, ""),
    row("vector", "list<float>", Decide, ""),
];

const POSTGRES_ICEBERG: &[MapRow] = &[
    row("smallint", "int", Widened, ""),
    row("integer", "int", Exact, ""),
    row("bigint", "long", Exact, ""),
    row(
        "serial, bigserial, smallserial",
        "int, long",
        Lossy,
        "The sequence is not carried: keys must come from the writer.",
    ),
    row("numeric(p,s), p ≤ 38", "decimal(p,s)", Exact, ""),
    row("numeric (no precision)", "decimal(38,s)", Lossy, "Unbounded in PostgreSQL: choose a precision and scale."),
    row("numeric(p,s), p > 38", "no type", Grade::None, "Iceberg decimals stop at 38 digits."),
    row("real, double precision", "float, double", Exact, ""),
    row("char, varchar, text", "string", Widened, "The length limit is not kept."),
    row("uuid", "uuid", Exact, ""),
    row("bytea", "binary", Exact, ""),
    row("boolean", "boolean", Exact, ""),
    row("date, time", "date, time", Exact, ""),
    row("timestamp", "timestamp", Exact, ""),
    row("timestamptz", "timestamptz", Exact, ""),
    row("timetz", "no type", Grade::None, "Keep the time and the offset apart."),
    row("interval", "no type", Grade::None, "Keep it as a number of microseconds, or a string."),
    row("json, jsonb", "string (variant in format 3)", Lossy, ""),
    row("arrays", "list", Exact, "A multi-dimensional array becomes a list of lists."),
    row(
        "types of its own (enum, domain, composite)",
        "string, or a struct",
        Lossy,
        "An enum's allowed values are not kept: keep them as a rule.",
    ),
    row("money", "decimal(19,2)", Lossy, "The currency's scale is set by the server, not the column."),
    row("inet, cidr, macaddr", "string", Lossy, ""),
    row("ranges, tsvector, xml, geometric types", "string", Lossy, ""),
    row("bit, varbit", "binary", Decide, "bit(1) used as a flag: choose boolean."),
];

const MYSQL_POSTGRES: &[MapRow] = &[
    row("tinyint", "smallint", Widened, "tinyint(1) used as a flag: choose boolean."),
    row("smallint", "smallint", Exact, ""),
    row("mediumint", "integer", Widened, ""),
    row("int", "integer", Exact, ""),
    row("int unsigned", "bigint", Widened, "PostgreSQL has no unsigned types."),
    row("bigint", "bigint", Exact, ""),
    row("bigint unsigned", "numeric(20,0)", Widened, ""),
    row("decimal(p,s)", "numeric(p,s)", Exact, ""),
    row("float, double", "real, double precision", Exact, ""),
    row("char, varchar", "char, varchar", Exact, ""),
    row("text, mediumtext, longtext", "text", Exact, ""),
    row("enum", "an enum type, or a check", Decide, "The type must be created first."),
    row("set", "text[]", Decide, ""),
    row("date", "date", Exact, ""),
    row("datetime", "timestamp", Exact, ""),
    row("timestamp", "timestamptz", Exact, ""),
    row("time", "time, or interval", Lossy, "MySQL time runs to ±838 hours; PostgreSQL time is a time of day."),
    row("year", "smallint", Widened, ""),
    row("json", "jsonb", Exact, ""),
    row("binary, varbinary, blob", "bytea", Exact, ""),
    row("bit", "bit", Exact, ""),
    row("boolean", "boolean", Exact, ""),
    row("geometry and the other spatial types", "PostGIS geometry", Decide, "Needs the PostGIS extension."),
    row("vector", "vector (pgvector)", Decide, "Needs the pgvector extension."),
    row("smallint unsigned, mediumint unsigned", "integer", Widened, ""),
];

const POSTGRES_MYSQL: &[MapRow] = &[
    row("smallint, integer, bigint", "SMALLINT, INT, BIGINT", Exact, ""),
    row("serial, bigserial, smallserial", "AUTO_INCREMENT", Exact, ""),
    row("numeric(p,s), p ≤ 65", "DECIMAL(p,s)", Exact, ""),
    row("numeric (no precision)", "DECIMAL(65,30)", Lossy, "Unbounded in PostgreSQL: choose a precision and scale."),
    row("numeric(p,s), p > 65", "no type", Grade::None, "MySQL decimals stop at 65 digits."),
    row("real, double precision", "FLOAT, DOUBLE", Exact, ""),
    row("boolean", "TINYINT(1)", Exact, ""),
    row("char, varchar", "CHAR, VARCHAR", Exact, ""),
    row("text", "LONGTEXT", Exact, "A key or an index needs VARCHAR(n)."),
    row("uuid", "BINARY(16) or CHAR(36)", Decide, "MySQL has no uuid type."),
    row("timestamp", "DATETIME(6)", Exact, ""),
    row(
        "timestamptz",
        "DATETIME(6) as UTC, or TIMESTAMP",
        Lossy,
        "DATETIME keeps no zone; TIMESTAMP only covers 1970–2038.",
    ),
    row("date", "DATE", Exact, ""),
    row("time", "TIME(6)", Exact, ""),
    row("timetz, interval", "no type", Grade::None, ""),
    row("json, jsonb", "JSON", Exact, ""),
    row("arrays", "JSON, or a child table", Lossy, "MySQL has no array type."),
    row("bytea", "LONGBLOB", Exact, ""),
    row("types of its own (enum, domain, composite)", "ENUM, the base type, or JSON", Decide, ""),
    row("inet, cidr, macaddr", "VARCHAR(45)", Lossy, ""),
    row("money", "DECIMAL(19,2)", Lossy, "The currency's scale is set by the server, not the column."),
    row("ranges, tsvector, xml, geometric types", "TEXT", Lossy, ""),
    row("bit, varbit", "BIT", Exact, ""),
];

/// Every map, by the pair it converts.
pub const MAPS: &[TypeMap] = &[
    TypeMap { id: "iceberg-mysql", from: Target::Iceberg, to: Target::Mysql, rows: ICEBERG_MYSQL },
    TypeMap { id: "iceberg-postgres", from: Target::Iceberg, to: Target::Postgres, rows: ICEBERG_POSTGRES },
    TypeMap { id: "mysql-iceberg", from: Target::Mysql, to: Target::Iceberg, rows: MYSQL_ICEBERG },
    TypeMap { id: "postgres-iceberg", from: Target::Postgres, to: Target::Iceberg, rows: POSTGRES_ICEBERG },
    TypeMap { id: "mysql-postgres", from: Target::Mysql, to: Target::Postgres, rows: MYSQL_POSTGRES },
    TypeMap { id: "postgres-mysql", from: Target::Postgres, to: Target::Mysql, rows: POSTGRES_MYSQL },
];

/// The map from `from` to `to`.
#[must_use]
pub fn map(from: Target, to: Target) -> Option<&'static TypeMap> {
    MAPS.iter().find(|m| m.from == from && m.to == to)
}

impl TypeMap {
    /// The line of this map that covers `t`; none for a type kept as read, or one the map does not know.
    #[must_use]
    pub fn row(&self, t: &DataType) -> Option<&'static MapRow> {
        let i = match (self.from, self.to) {
            (Target::Iceberg, Target::Mysql) => iceberg_mysql(t),
            (Target::Iceberg, Target::Postgres) => iceberg_postgres(t),
            (Target::Mysql, Target::Iceberg) => mysql_iceberg(t),
            (Target::Postgres, Target::Iceberg) => postgres_iceberg(t),
            (Target::Mysql, Target::Postgres) => mysql_postgres(t),
            (Target::Postgres, Target::Mysql) => postgres_mysql(t),
            _ => None,
        }?;
        self.rows.get(i)
    }
}

fn is_struct(t: Option<&DataType>) -> bool {
    t.is_some_and(|t| t.name == "struct")
}

fn iceberg_mysql(t: &DataType) -> Option<usize> {
    Some(match t.name.as_str() {
        "boolean" => 0,
        "int" => 1,
        "long" => 2,
        "float" | "double" => 3,
        "decimal" => 4,
        "date" => 5,
        "time" => 6,
        "timestamp" => 7,
        "timestamptz" => 8,
        "string" => 9,
        "uuid" => 10,
        "binary" | "fixed" => 11,
        "struct" => 12,
        "list" if is_struct(t.of.as_deref()) => 18,
        "list" => 13,
        "map" => 14,
        "timestamp_ns" | "timestamptz_ns" => 15,
        "variant" => 16,
        "geometry" | "geography" => 17,
        _ => return None,
    })
}

fn iceberg_postgres(t: &DataType) -> Option<usize> {
    Some(match t.name.as_str() {
        "boolean" => 0,
        "int" | "long" => 1,
        "float" | "double" => 2,
        "decimal" => 3,
        "date" | "time" => 4,
        "timestamp" | "timestamptz" => 5,
        "string" => 6,
        "uuid" => 7,
        "binary" => 8,
        "fixed" => 9,
        "list" if is_struct(t.of.as_deref()) => 12,
        "list" if t.of.as_deref().is_some_and(|e| e.name == "map") => 13,
        "list" => 10,
        "struct" => 11,
        "map" => 13,
        "timestamp_ns" | "timestamptz_ns" => 14,
        "variant" => 15,
        "geometry" | "geography" => 16,
        _ => return None,
    })
}

const SPATIAL_MYSQL: &[&str] = &[
    "geometry",
    "point",
    "linestring",
    "polygon",
    "multipoint",
    "multilinestring",
    "multipolygon",
    "geometrycollection",
];

fn mysql_iceberg(t: &DataType) -> Option<usize> {
    let n = t.name.as_str();
    Some(match n {
        "tinyint" | "smallint" | "mediumint" => 0,
        "int" if t.unsigned => 2,
        "int" => 1,
        "bigint" if t.unsigned => 4,
        "bigint" => 3,
        "decimal" if t.precision.is_some_and(|p| p > 38) => 6,
        "decimal" => 5,
        "float" | "double" => 7,
        "char" | "varchar" | "tinytext" | "text" | "mediumtext" | "longtext" => 8,
        "enum" | "set" => 9,
        "date" => 10,
        "datetime" => 11,
        "timestamp" => 12,
        "time" => 13,
        "year" => 14,
        "json" => 15,
        "bit" => 16,
        "binary" | "varbinary" | "tinyblob" | "blob" | "mediumblob" | "longblob" => 17,
        "boolean" => 18,
        "vector" => 20,
        _ if SPATIAL_MYSQL.contains(&n) => 19,
        _ => return None,
    })
}

fn postgres_iceberg(t: &DataType) -> Option<usize> {
    Some(match t.name.as_str() {
        "smallint" => 0,
        "integer" => 1,
        "bigint" => 2,
        "serial" | "bigserial" | "smallserial" => 3,
        "numeric" if t.precision.is_none() => 5,
        "numeric" if t.precision.is_some_and(|p| p > 38) => 6,
        "numeric" => 4,
        "real" | "double precision" => 7,
        "char" | "varchar" | "text" => 8,
        "uuid" => 9,
        "bytea" => 10,
        "boolean" => 11,
        "time" if t.with_time_zone => 15,
        "date" | "time" => 12,
        "timestamp" if t.with_time_zone => 14,
        "timestamp" => 13,
        "interval" => 16,
        "json" | "jsonb" => 17,
        "array" => 18,
        "user" => 19,
        "money" => 20,
        "inet" | "cidr" | "macaddr" | "macaddr8" => 21,
        "bit" | "varbit" => 23,
        "verbatim" => return None,
        _ => 22,
    })
}

fn mysql_postgres(t: &DataType) -> Option<usize> {
    let n = t.name.as_str();
    Some(match n {
        "tinyint" => 0,
        "smallint" | "mediumint" if t.unsigned => 24,
        "smallint" => 1,
        "mediumint" => 2,
        "int" if t.unsigned => 4,
        "int" => 3,
        "bigint" if t.unsigned => 6,
        "bigint" => 5,
        "decimal" => 7,
        "float" | "double" => 8,
        "char" | "varchar" => 9,
        "tinytext" | "text" | "mediumtext" | "longtext" => 10,
        "enum" => 11,
        "set" => 12,
        "date" => 13,
        "datetime" => 14,
        "timestamp" => 15,
        "time" => 16,
        "year" => 17,
        "json" => 18,
        "binary" | "varbinary" | "tinyblob" | "blob" | "mediumblob" | "longblob" => 19,
        "bit" => 20,
        "boolean" => 21,
        "vector" => 23,
        _ if SPATIAL_MYSQL.contains(&n) => 22,
        _ => return None,
    })
}

fn postgres_mysql(t: &DataType) -> Option<usize> {
    Some(match t.name.as_str() {
        "smallint" | "integer" | "bigint" => 0,
        "serial" | "bigserial" | "smallserial" => 1,
        "numeric" if t.precision.is_none() => 3,
        "numeric" if t.precision.is_some_and(|p| p > 65) => 4,
        "numeric" => 2,
        "real" | "double precision" => 5,
        "boolean" => 6,
        "char" | "varchar" => 7,
        "text" => 8,
        "uuid" => 9,
        "timestamp" if t.with_time_zone => 11,
        "timestamp" => 10,
        "date" => 12,
        "time" if t.with_time_zone => 14,
        "time" => 13,
        "interval" => 14,
        "json" | "jsonb" => 15,
        "array" => 16,
        "bytea" => 17,
        "user" => 18,
        "inet" | "cidr" | "macaddr" | "macaddr8" => 19,
        "money" => 20,
        "bit" | "varbit" => 22,
        "verbatim" => return None,
        _ => 21,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(name: &str) -> DataType {
        DataType::named(name)
    }

    #[test]
    fn every_pair_has_a_map_and_every_index_is_a_row() {
        for from in [Target::Mysql, Target::Postgres, Target::Iceberg] {
            for to in [Target::Mysql, Target::Postgres, Target::Iceberg] {
                assert_eq!(map(from, to).is_some(), from != to, "{from:?} → {to:?}");
            }
        }
        for m in MAPS {
            for name in crate::types::names(m.from) {
                let mut dt = t(name);
                for unsigned in [false, true] {
                    dt.unsigned = unsigned;
                    if let Some(r) = m.row(&dt) {
                        assert!(!r.from.is_empty(), "{} {name}", m.id);
                    }
                }
            }
        }
    }

    #[test]
    fn grades_follow_the_types() {
        let ice_my = map(Target::Iceberg, Target::Mysql).unwrap();
        assert_eq!(ice_my.row(&t("string")).unwrap().grade, Decide);
        assert_eq!(ice_my.row(&t("map")).unwrap().grade, Lossy);
        let mut list = t("list");
        list.of = Some(Box::new(t("struct")));
        assert_eq!(ice_my.row(&list).unwrap().from, "list<struct>");
        let my_ice = map(Target::Mysql, Target::Iceberg).unwrap();
        let mut big = t("bigint");
        big.unsigned = true;
        assert_eq!(my_ice.row(&big).unwrap().to, "decimal(20,0)");
        let mut wide = t("decimal");
        wide.precision = Some(40);
        assert_eq!(my_ice.row(&wide).unwrap().grade, Grade::None);
        let pg_ice = map(Target::Postgres, Target::Iceberg).unwrap();
        assert_eq!(pg_ice.row(&t("numeric")).unwrap().grade, Lossy, "numeric without a precision");
        let mut tz = t("timestamp");
        tz.with_time_zone = true;
        assert_eq!(pg_ice.row(&tz).unwrap().to, "timestamptz");
        assert_eq!(map(Target::Iceberg, Target::Postgres).unwrap().row(&t("verbatim")), None);
    }
}
