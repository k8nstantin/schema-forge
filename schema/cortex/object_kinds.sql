-- cortex.object_kinds: the kinds of object each engine has, the versions that have each, and the plugin table that holds each kind's details; an object of a kind its design's engine or version lacks cannot be stored.
CREATE TABLE cortex.object_kinds (
  id             TEXT NOT NULL PRIMARY KEY,                                                -- <engine>/<kind>: mysql/table
  engine         TEXT NOT NULL REFERENCES cortex.engines (id) ON DELETE CASCADE,           -- the engine
  kind           TEXT NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_]*$'),                         -- as an object names its kind (table, view, procedure)
  name           TEXT NOT NULL CHECK (length(name) >= 1),                                  -- as people say it (Table)
  has_columns    BOOLEAN NOT NULL,                                                         -- true when its objects have columns the canvas draws (a table, a view)
  details        TEXT,                                                                     -- the plugin table that extends its objects (tables); NULL when the cortex says all of it
  position       NUMERIC NOT NULL CHECK (position > 0),                                    -- its place in the engine's list of kinds
  since          TEXT,                                                                     -- the first version of the engine that has it (9.7 for a JavaScript library); NULL for every version
  "until"        TEXT,                                                                     -- the last version that has it; NULL for every later one
  details_plugin TEXT GENERATED ALWAYS AS (CASE WHEN details IS NULL THEN NULL ELSE engine END) STORED,  -- the plugin of its details table: its engine's
  UNIQUE (engine, kind),
  UNIQUE (engine, position),
  CHECK (id = engine || '/' || kind),
  FOREIGN KEY (details_plugin, details) REFERENCES cortex.plugin_tables (plugin, name) ON DELETE RESTRICT,
  FOREIGN KEY (engine, since) REFERENCES cortex.engine_versions (engine, version),
  FOREIGN KEY (engine, "until") REFERENCES cortex.engine_versions (engine, version)
);
