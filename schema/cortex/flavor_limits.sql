-- cortex.flavor_limits: what a flavor lacks of its engine, one fact a row, each with where it was read: a kind of object, an option, one value of an option, a function a routine may call, an extension, or a version. The guard refuses what a design's flavor lacks (severity refused); cortex.misfits lists both kinds for a design and a target. Owner: cortex.
CREATE TABLE cortex.flavor_limits (
  id        TEXT NOT NULL PRIMARY KEY,                                                                                     -- <flavor>/<what>/<name>: mysql/cloudsql/kind/loadable_function
  flavor    TEXT NOT NULL REFERENCES cortex.engine_flavors (id) DEFERRABLE INITIALLY DEFERRED,                             -- the flavor that lacks it
  what      TEXT NOT NULL CHECK (what IN ('kind', 'option', 'value', 'function', 'extension', 'version')),                 -- what sort of thing it lacks
  kind      TEXT REFERENCES cortex.object_kinds (id) DEFERRABLE INITIALLY DEFERRED,                                        -- the kind it lacks (what kind); NULL otherwise
  option    TEXT REFERENCES cortex.option_declarations (id) DEFERRABLE INITIALLY DEFERRED,                                 -- the option it lacks, or whose value it lacks (what option, value); NULL otherwise
  value     JSONB,                                                                                                         -- the option's value it lacks (what value): "MyISAM"; NULL otherwise
  name      TEXT CHECK (length(name) >= 1),                                                                                -- the function or extension it lacks, as SQL names it (LOAD_FILE, plpython3u); NULL otherwise
  version   TEXT REFERENCES cortex.engine_versions (id) DEFERRABLE INITIALLY DEFERRED,                                     -- the engine version it does not offer (what version); NULL otherwise
  since     TEXT REFERENCES cortex.engine_versions (id) DEFERRABLE INITIALLY DEFERRED,                                     -- the first engine version it lacks it in; NULL for every one
  "until"   TEXT REFERENCES cortex.engine_versions (id) DEFERRABLE INITIALLY DEFERRED,                                     -- the last engine version it lacks it in; NULL for every later one
  severity  TEXT NOT NULL DEFAULT 'refused' CHECK (severity IN ('refused', 'warned')),                                     -- refused: the flavor will not take it, and the guard refuses it; warned: it takes it with a cost the about states
  about     TEXT NOT NULL CHECK (length(about) >= 1),                                                                      -- what it means for a design, in a sentence
  source    TEXT NOT NULL CHECK (source ~ '^https://'),                                                                    -- the page of the flavor's documentation that says so
  CHECK ((what = 'kind') = (kind IS NOT NULL)),
  CHECK ((what IN ('option', 'value')) = (option IS NOT NULL)),
  CHECK ((what = 'value') = (value IS NOT NULL)),
  CHECK ((what IN ('function', 'extension')) = (name IS NOT NULL)),
  CHECK ((what = 'version') = (version IS NOT NULL))
);

CREATE INDEX flavor_limits_flavor ON cortex.flavor_limits (flavor, what);

COMMENT ON TABLE cortex.flavor_limits IS 'what a flavor lacks of its engine, one fact a row, each with where it was read: a kind of object, an option, one value of an option, a function a routine may call, an extension, or a version. The guard refuses what a design''s flavor lacks (severity refused); cortex.misfits lists both kinds for a design and a target.';
COMMENT ON COLUMN cortex.flavor_limits.id IS '<flavor>/<what>/<name>: mysql/cloudsql/kind/loadable_function';
COMMENT ON COLUMN cortex.flavor_limits.flavor IS 'the flavor that lacks it';
COMMENT ON COLUMN cortex.flavor_limits.what IS 'what sort of thing it lacks';
COMMENT ON COLUMN cortex.flavor_limits.kind IS 'the kind it lacks (what kind); NULL otherwise';
COMMENT ON COLUMN cortex.flavor_limits.option IS 'the option it lacks, or whose value it lacks (what option, value); NULL otherwise';
COMMENT ON COLUMN cortex.flavor_limits.value IS 'the option''s value it lacks (what value): "MyISAM"; NULL otherwise';
COMMENT ON COLUMN cortex.flavor_limits.name IS 'the function or extension it lacks, as SQL names it (LOAD_FILE, plpython3u); NULL otherwise';
COMMENT ON COLUMN cortex.flavor_limits.version IS 'the engine version it does not offer (what version); NULL otherwise';
COMMENT ON COLUMN cortex.flavor_limits.since IS 'the first engine version it lacks it in; NULL for every one';
COMMENT ON COLUMN cortex.flavor_limits."until" IS 'the last engine version it lacks it in; NULL for every later one';
COMMENT ON COLUMN cortex.flavor_limits.severity IS 'refused: the flavor will not take it, and the guard refuses it; warned: it takes it with a cost the about states';
COMMENT ON COLUMN cortex.flavor_limits.about IS 'what it means for a design, in a sentence';
COMMENT ON COLUMN cortex.flavor_limits.source IS 'the page of the flavor''s documentation that says so';
