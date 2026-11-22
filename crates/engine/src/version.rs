//! Versions, and the versions a feature is in.

/// A version of an engine's database (`"3"`, `"8.4"`, `"17"`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Version {
    /// As a schema names it.
    pub id: &'static str,
    /// As people say it (`"format 3"`, `"8.4"`).
    pub name: &'static str,
}

/// The versions a feature is in: from the one it came in, up to but not including the one that took it away. An
/// open end is every version on that side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Availability {
    pub since: Option<&'static str>,
    pub until: Option<&'static str>,
}

impl Availability {
    /// In every version.
    pub const ALWAYS: Self = Self { since: None, until: None };

    /// From `version` on.
    #[must_use]
    pub const fn since(version: &'static str) -> Self {
        Self { since: Some(version), until: None }
    }

    /// Whether the feature is in `version`, by the order of `versions` (oldest first). A version not in the list has
    /// no features but those in every version.
    #[must_use]
    pub fn in_version(&self, version: &str, versions: &[Version]) -> bool {
        let at = |id: &str| versions.iter().position(|v| v.id == id);
        let Some(v) = at(version) else { return self.since.is_none() && self.until.is_none() };
        let after_since = self.since.is_none_or(|s| at(s).is_some_and(|s| s <= v));
        let before_until = self.until.is_none_or(|u| at(u).is_some_and(|u| v < u));
        after_since && before_until
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const V: &[Version] =
        &[Version { id: "1", name: "one" }, Version { id: "2", name: "two" }, Version { id: "3", name: "three" }];

    #[test]
    fn a_feature_is_in_the_versions_from_its_since_to_its_until() {
        let a = Availability::since("2");
        assert_eq!(["1", "2", "3"].map(|v| a.in_version(v, V)), [false, true, true]);
        let gone = Availability { since: None, until: Some("3") };
        assert_eq!(["1", "2", "3"].map(|v| gone.in_version(v, V)), [true, true, false]);
        assert!(Availability::ALWAYS.in_version("2", V));
    }

    #[test]
    fn an_unknown_version_has_only_what_every_version_has() {
        assert!(Availability::ALWAYS.in_version("9", V));
        assert!(!Availability::since("2").in_version("9", V));
        assert!(!Availability::since("7").in_version("3", V), "a since that is not a version is never reached");
    }
}
