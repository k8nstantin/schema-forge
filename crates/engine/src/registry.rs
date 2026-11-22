//! The registry: the engines a build of Schema Forge has, by id. The only place that lists them is the registry crate
//! that builds this; everything else asks it.

use std::path::Path;

use schema_forge_model::Schema;

use crate::{Engine, Input};

/// The engines, by id.
#[derive(Default)]
pub struct Registry {
    engines: Vec<Box<dyn Engine>>,
}

impl Registry {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds `engine`.
    ///
    /// # Panics
    /// When an engine with its id is registered already: two engines for one database is a build mistake.
    #[must_use]
    pub fn with(mut self, engine: impl Engine + 'static) -> Self {
        assert!(self.get(engine.id()).is_none(), "the engine `{}` is registered twice", engine.id());
        self.engines.push(Box::new(engine));
        self
    }

    /// Every engine, in the order registered.
    pub fn all(&self) -> impl Iterator<Item = &dyn Engine> {
        self.engines.iter().map(AsRef::as_ref)
    }

    #[must_use]
    pub fn get(&self, id: &str) -> Option<&dyn Engine> {
        self.all().find(|e| e.id() == id)
    }

    /// The engine `schema` is designed for.
    ///
    /// # Errors
    /// When this build has no such engine.
    pub fn of(&self, schema: &Schema) -> Result<&dyn Engine, String> {
        self.get(&schema.engine.id).ok_or_else(|| {
            format!("the schema is for `{}`, which this build has no engine for ({})", schema.engine.id, self.ids())
        })
    }

    /// The one engine that reads `path`.
    ///
    /// # Errors
    /// When it cannot be read, or no engine or more than one recognises it: then the engine is named by the person.
    pub fn reader_of(&self, path: &Path) -> Result<(&dyn Engine, Input), String> {
        let input = Input::open(path)?;
        let found: Vec<&dyn Engine> = self.all().filter(|e| e.read().is_some_and(|r| r.recognises(&input))).collect();
        match found.as_slice() {
            [one] => Ok((*one, input)),
            [] => {
                let readers: Vec<String> =
                    self.all().filter_map(|e| e.read().map(|r| format!("{} ({})", e.name(), r.reads()))).collect();
                Err(format!(
                    "{}: no engine recognises it; say which engine it is for. Read here: {}",
                    path.display(),
                    if readers.is_empty() { "nothing".to_string() } else { readers.join(", ") }
                ))
            }
            many => Err(format!(
                "{}: more than one engine recognises it ({}); say which engine it is for",
                path.display(),
                many.iter().map(|e| e.name()).collect::<Vec<_>>().join(", ")
            )),
        }
    }

    fn ids(&self) -> String {
        let ids: Vec<&str> = self.all().map(Engine::id).collect();
        if ids.is_empty() { "it has none".to_string() } else { format!("it has {}", ids.join(", ")) }
    }
}
