//! The skeleton's parts. Order is meaning: namespaces, objects and columns keep the order they were made or read in.

use serde::{Deserialize, Serialize};

use crate::Id;

/// The format of the schema file this crate reads and writes.
pub const FORMAT: u32 = 2;

/// An engine's own data on a part of the schema: JSON the engine describes, checks and changes, stored and versioned
/// by the skeleton without reading it.
pub type Section = serde_json::Map<String, serde_json::Value>;

/// A whole schema, designed for one engine.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Schema {
    pub format: u32,
    pub engine: EngineRef,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub namespaces: Vec<Namespace>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub objects: Vec<Object>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub links: Vec<Link>,
    /// Areas group objects for the Categories and Map perspectives, whatever their namespace.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub areas: Vec<Area>,
    /// The engine's own data on the schema as a whole.
    #[serde(default, skip_serializing_if = "Section::is_empty")]
    pub engine_section: Section,
}

/// The engine a schema is designed for, and the version of it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EngineRef {
    /// The engine's id in the registry.
    pub id: String,
    /// One of the engine's versions; it decides which features the schema is offered.
    pub version: String,
}

/// A namespace: a level that holds objects, nested under another or at the top. The engine names the level and says
/// how deep namespaces go.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Namespace {
    pub id: Id,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<Id>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    #[serde(default, skip_serializing_if = "Section::is_empty")]
    pub engine: Section,
}

/// Something a namespace holds: a table, a view, whatever kinds the engine has.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Object {
    pub id: Id,
    /// One of the engine's kinds of object.
    pub kind: String,
    pub namespace: Id,
    pub name: String,
    /// What it holds, in a sentence or two: the comment the engine writes into its SQL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    /// Longer notes for people and the agent, never written into SQL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub area: Option<Id>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub columns: Vec<Column>,
    /// The objects this one is made from or reads (a view's query): the engine works them out.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reads: Vec<Id>,
    #[serde(default, skip_serializing_if = "Section::is_empty")]
    pub engine: Section,
}

/// A column of an object.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Column {
    pub id: Id,
    pub name: String,
    /// Its type, as the engine writes it; only the engine reads it.
    #[serde(rename = "type")]
    pub data_type: String,
    /// Whether it may hold null.
    pub null: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    #[serde(default, skip_serializing_if = "Section::is_empty")]
    pub engine: Section,
}

/// A link from columns of one object to columns of another, as the Map draws it. Whether the engine enforces it, and
/// how, is in its section.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Link {
    pub id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub from: Ends,
    pub to: Ends,
    #[serde(default, skip_serializing_if = "Section::is_empty")]
    pub engine: Section,
}

/// One end of a link: an object and its columns, in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ends {
    pub object: Id,
    pub columns: Vec<Id>,
}

/// A group of objects, by subject (billing, catalog), across namespaces.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Area {
    pub id: Id,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub colour: Option<String>,
}

impl Schema {
    /// An empty schema for `engine` at `version`.
    #[must_use]
    pub fn new(engine: &str, version: &str) -> Self {
        Self {
            format: FORMAT,
            engine: EngineRef { id: engine.to_string(), version: version.to_string() },
            namespaces: Vec::new(),
            objects: Vec::new(),
            links: Vec::new(),
            areas: Vec::new(),
            engine_section: Section::new(),
        }
    }

    /// Reads a schema file.
    ///
    /// # Errors
    /// When the text is not a schema of this format.
    pub fn from_json(text: &str) -> Result<Self, String> {
        let value: serde_json::Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
        match value.get("format").and_then(serde_json::Value::as_u64) {
            Some(f) if f == u64::from(FORMAT) => {}
            Some(f) => return Err(format!("this is a format {f} schema; this version reads format {FORMAT}")),
            None => return Err("not a schema: it says no format".to_string()),
        }
        serde_json::from_value(value).map_err(|e| e.to_string())
    }

    /// The schema as its file: pretty JSON, in the model's order.
    #[must_use]
    pub fn to_json(&self) -> String {
        let mut s = serde_json::to_string_pretty(self).unwrap_or_default();
        s.push('\n');
        s
    }

    /// Every id the schema holds, each part's own and its columns'.
    pub fn ids(&self) -> impl Iterator<Item = &Id> {
        self.namespaces
            .iter()
            .map(|n| &n.id)
            .chain(self.objects.iter().flat_map(|o| std::iter::once(&o.id).chain(o.columns.iter().map(|c| &c.id))))
            .chain(self.links.iter().map(|l| &l.id))
            .chain(self.areas.iter().map(|a| &a.id))
    }

    #[must_use]
    pub fn namespace(&self, id: &Id) -> Option<&Namespace> {
        self.namespaces.iter().find(|n| &n.id == id)
    }

    #[must_use]
    pub fn object(&self, id: &Id) -> Option<&Object> {
        self.objects.iter().find(|o| &o.id == id)
    }

    /// The column `id` and the object holding it.
    #[must_use]
    pub fn column(&self, id: &Id) -> Option<(&Object, &Column)> {
        self.objects.iter().find_map(|o| o.columns.iter().find(|c| &c.id == id).map(|c| (o, c)))
    }

    /// A namespace's names from the top down to it (`["lake", "sales"]`); empty for an unknown id, and cut short at
    /// a cycle, which the checks report.
    #[must_use]
    pub fn path(&self, id: &Id) -> Vec<&str> {
        let mut out = Vec::new();
        let mut seen = Vec::new();
        let mut at = self.namespace(id);
        while let Some(n) = at {
            if seen.contains(&&n.id) {
                break;
            }
            seen.push(&n.id);
            out.push(n.name.as_str());
            at = n.parent.as_ref().and_then(|p| self.namespace(p));
        }
        out.reverse();
        out
    }
}

impl Object {
    #[must_use]
    pub fn column_named(&self, name: &str) -> Option<&Column> {
        self.columns.iter().find(|c| c.name == name)
    }
}
