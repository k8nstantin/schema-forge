//! MySQL's versions, and what each changed that a schema can hold: the types, the kinds, the reader, the writer and the
//! checks all ask these. A new MySQL release is a row in `VERSIONS` and a `Feature` for each change it brings; nothing
//! else tests a version.

use schema_forge_engine::{Availability, Version};

/// Oldest first. 9.7 is the last of the sequential numbers; MySQL numbers its releases by year and month after it.
pub const VERSIONS: &[Version] = &[
    Version::new("8.0", "MySQL 8.0"),
    Version::new("8.4", "MySQL 8.4"),
    Version::new("9.7", "MySQL 9.7"),
    Version::new("26.7", "MySQL 26.7"),
    Version::new("26.10", "MySQL 26.10"),
];

/// The version a new schema starts at: the long-term release most databases run.
pub const DEFAULT: &str = "8.4";

/// A change a version brought to what a schema can hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Feature {
    pub id: &'static str,
    /// What it is, as the person is told when their version does not have it.
    pub what: &'static str,
    pub available: Availability,
}

/// `AUTO_INCREMENT` on a `FLOAT` or `DOUBLE` column (removed in 8.4).
pub const AUTO_INCREMENT_FLOAT: Feature = Feature {
    id: "auto_increment_float",
    what: "AUTO_INCREMENT on a FLOAT or DOUBLE column",
    available: Availability::until("8.4"),
};
/// A foreign key to columns that are not a primary key or a unique (refused by default from 8.4).
pub const NONSTANDARD_FOREIGN_KEY: Feature = Feature {
    id: "nonstandard_foreign_key",
    what: "a foreign key to columns that are not a primary key or a unique",
    available: Availability::until("8.4"),
};
/// A column prefix in a partitioning key (removed in 8.4).
pub const PARTITION_KEY_PREFIX: Feature = Feature {
    id: "partition_key_prefix",
    what: "a column prefix in a partitioning key",
    available: Availability::until("8.4"),
};
/// The `VECTOR(N)` type (from 9.0).
pub const VECTOR: Feature = Feature { id: "vector", what: "the VECTOR type", available: Availability::since("9.7") };
/// A foreign key written on its column (`REFERENCES`), enforced (from 9.0).
pub const INLINE_REFERENCES: Feature = Feature {
    id: "inline_references",
    what: "a foreign key written on its column (REFERENCES), enforced",
    available: Availability::since("9.7"),
};
/// JavaScript stored programs and libraries (9.0, 9.2).
pub const LIBRARIES: Feature = Feature {
    id: "libraries",
    what: "JavaScript and WASM libraries and stored programs",
    available: Availability::since("9.7"),
};

/// Whether `version` has `feature`.
#[must_use]
pub fn has(version: &str, feature: &Feature) -> bool {
    feature.available.in_version(version, VERSIONS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_feature_is_in_the_versions_the_release_notes_say() {
        let in_ = |f: &Feature| VERSIONS.iter().filter(|v| has(v.id, f)).map(|v| v.id).collect::<Vec<_>>();
        assert_eq!(in_(&AUTO_INCREMENT_FLOAT), ["8.0"]);
        assert_eq!(in_(&VECTOR), ["9.7", "26.7", "26.10"]);
        assert!(VERSIONS.iter().any(|v| v.id == DEFAULT));
        for f in
            [AUTO_INCREMENT_FLOAT, NONSTANDARD_FOREIGN_KEY, PARTITION_KEY_PREFIX, VECTOR, INLINE_REFERENCES, LIBRARIES]
        {
            for end in [f.available.since, f.available.until].into_iter().flatten() {
                assert!(VERSIONS.iter().any(|v| v.id == end), "{} names {end}", f.id);
            }
        }
    }
}
