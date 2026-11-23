//! The MySQL engine: everything Schema Forge knows about MySQL (see this crate's README.md). Built as any engine
//! written outside Schema Forge would be, on the model and the engine interface alone.

/// A value of the layout made from its default and set by field: the layout's types are non-exhaustive, so a field
/// added to them later breaks nothing here.
macro_rules! with {
    ($t:ty { $($f:ident : $v:expr),* $(,)? }) => {{
        let mut x = <$t>::default();
        $(x.$f = $v;)*
        x
    }};
}

mod addon;
mod checks;
mod dump;
mod kinds;
mod lex;
mod live;
mod options;
mod portable;
mod queries;
mod read;
mod types;
mod versions;
mod write;

pub use addon::AddOn;
pub use types::{Family, Params};

use schema_forge_engine::kinds::ObjectKind;
use schema_forge_engine::live::{Field, Live, Profile, Secret, Step};
use schema_forge_engine::options::OptionSpec;
use schema_forge_engine::portable::{ArrowType, Mapped, Portable};
use schema_forge_engine::{
    Checks, Engine, Imported, Input, Parsed, Queries, Read, TypeError, TypeGroup, TypeSpec, Types, Version, Write,
};
use schema_forge_model::{Id, Problem, Schema};

/// The MySQL engine, with the add-ons registered on it.
pub struct Mysql {
    families: Vec<Family>,
    catalog: Vec<TypeSpec>,
    add_ons: Vec<Box<dyn AddOn>>,
}

impl Mysql {
    /// MySQL with no add-ons.
    #[must_use]
    pub fn new() -> Self {
        let families = types::BUILT_IN.to_vec();
        let catalog = types::catalog(&families);
        Self { families, catalog, add_ons: Vec::new() }
    }

    /// The same engine with `add_on` registered: its types join the catalog.
    #[must_use]
    pub fn with(mut self, add_on: impl AddOn + 'static) -> Self {
        self.families.extend_from_slice(add_on.types());
        self.catalog = types::catalog(&self.families);
        self.add_ons.push(Box::new(add_on));
        self
    }

    /// The add-ons registered on this engine, by name.
    pub fn add_ons(&self) -> impl Iterator<Item = &str> {
        self.add_ons.iter().map(|a| a.name())
    }
}

impl Default for Mysql {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine for Mysql {
    fn id(&self) -> &'static str {
        "mysql"
    }

    fn name(&self) -> &'static str {
        "MySQL"
    }

    fn versions(&self) -> &[Version] {
        versions::VERSIONS
    }

    fn default_version(&self) -> &'static str {
        versions::DEFAULT
    }

    fn types(&self) -> &dyn Types {
        self
    }

    fn kinds(&self) -> &[ObjectKind] {
        kinds::KINDS
    }

    fn options(&self) -> &[OptionSpec] {
        options::OPTIONS
    }

    fn read(&self) -> Option<&dyn Read> {
        Some(self)
    }

    fn write(&self) -> Option<&dyn Write> {
        Some(self)
    }

    fn queries(&self) -> Option<&dyn Queries> {
        Some(self)
    }

    fn checks(&self) -> Option<&dyn Checks> {
        Some(self)
    }

    fn live(&self) -> Option<&dyn Live> {
        Some(self)
    }

    fn portable(&self) -> Option<&dyn Portable> {
        Some(self)
    }
}

impl Live for Mysql {
    fn fields(&self) -> &[Field] {
        live::FIELDS
    }

    fn test(&self, profile: &Profile, secret: Option<&Secret>) -> Vec<Step> {
        live::test(profile, secret)
    }

    fn read(&self, profile: &Profile, secret: Option<&Secret>, which: &[String]) -> Result<Imported, String> {
        live::read(&self.families, profile, secret, which)
    }
}

impl Checks for Mysql {
    fn check(&self, schema: &Schema) -> Vec<Problem> {
        checks::check(schema)
    }
}

impl Portable for Mysql {
    fn arrow_type(&self, type_text: &str, version: &str) -> Result<Mapped<ArrowType>, TypeError> {
        portable::arrow_type(&self.families, type_text, version)
    }

    fn engine_type(&self, arrow: &ArrowType, version: &str) -> Mapped<String> {
        portable::engine_type(arrow, version)
    }
}

impl Write for Mysql {
    fn definition(&self, schema: &Schema, id: &Id) -> Result<Option<String>, String> {
        write::definition(schema, id)
    }

    fn schema(&self, schema: &Schema) -> Result<String, String> {
        write::schema(schema)
    }
}

impl Read for Mysql {
    fn reads(&self) -> &'static str {
        "mysqldump files and MySQL DDL"
    }

    fn recognises(&self, input: &Input) -> bool {
        read::recognises(input)
    }

    fn read(&self, input: &Input) -> Result<Imported, String> {
        // A whole dump holds rows as raw bytes, which need not be UTF-8. They are data, counted and left out; every
        // byte that ends a statement or a quote is ASCII, and stays where it is.
        let bytes = std::fs::read(&input.path).map_err(|e| format!("{}: {e}", input.path.display()))?;
        let text = String::from_utf8(bytes).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned());
        read::read(&self.families, text, read::version_of(&input.head))
    }
}

impl Queries for Mysql {
    fn reads(&self, query: &str) -> Result<Vec<Vec<String>>, String> {
        queries::reads(query)
    }
}

impl Types for Mysql {
    fn groups(&self) -> &[TypeGroup] {
        types::GROUPS
    }

    fn catalog(&self) -> &[TypeSpec] {
        &self.catalog
    }

    fn parse(&self, text: &str, version: &str) -> Result<Parsed, TypeError> {
        types::parse(&self.families, text, version)
    }
}
