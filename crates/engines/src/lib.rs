//! The engines Schema Forge ships with, registered. The apps ask this registry for an engine by id, or for the one
//! that reads a file; they never name a database themselves (docs/engines.md).

use schema_forge_engine::Registry;

/// Every engine this build ships.
#[must_use]
pub fn registry() -> Registry {
    Registry::new().with(schema_forge_mysql::Mysql::new())
}

/// Every engine this build ships, and Quill: the made-up database built unlike the real ones, so a test of shared
/// code that runs on every engine here fails wherever that code names one engine's vocabulary.
#[cfg(feature = "test-engines")]
#[must_use]
pub fn for_tests() -> Registry {
    registry().with(schema_forge_quill::Quill::new())
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_shipped_engines_are_registered_once_each() {
        let ids: Vec<&str> = super::registry().all().map(schema_forge_engine::Engine::id).collect();
        assert_eq!(ids, ["mysql"]);
    }

    #[cfg(feature = "test-engines")]
    #[test]
    fn tests_also_have_quill() {
        let ids: Vec<&str> = super::for_tests().all().map(schema_forge_engine::Engine::id).collect();
        assert_eq!(ids, ["mysql", "quill"]);
    }
}
