-- cortex.engine_features: what a version of an engine's database has or lacks (a type, a kind of object, an option, a clause), with the first and last version that has it. Owner: cortex.
CREATE TABLE cortex.engine_features (
  id       TEXT NOT NULL PRIMARY KEY,                       -- <engine>/<feature>: mysql/check_constraints
  engine   TEXT NOT NULL CHECK (engine ~ '^[a-z0-9_]+$'),   -- the engine
  feature  TEXT NOT NULL CHECK (feature ~ '^[a-z0-9_]+$'),  -- as the engine names it (vector, check_constraints)
  what     TEXT NOT NULL CHECK (length(what) >= 1),         -- what it is, in a few words (the VECTOR type)
  since    TEXT REFERENCES cortex.engine_versions (id),     -- the first version that has it; NULL for every version from the oldest
  "until"  TEXT REFERENCES cortex.engine_versions (id),     -- the last version that has it; NULL for every version to the newest
  detail   TEXT,                                            -- what a version alone does not say (enforced from 8.0.16); NULL for nothing
  UNIQUE (engine, feature),
  CHECK (id = engine || '/' || feature)
);

COMMENT ON TABLE cortex.engine_features IS 'what a version of an engine''s database has or lacks (a type, a kind of object, an option, a clause), with the first and last version that has it.';
COMMENT ON COLUMN cortex.engine_features.id IS '<engine>/<feature>: mysql/check_constraints';
COMMENT ON COLUMN cortex.engine_features.engine IS 'the engine';
COMMENT ON COLUMN cortex.engine_features.feature IS 'as the engine names it (vector, check_constraints)';
COMMENT ON COLUMN cortex.engine_features.what IS 'what it is, in a few words (the VECTOR type)';
COMMENT ON COLUMN cortex.engine_features.since IS 'the first version that has it; NULL for every version from the oldest';
COMMENT ON COLUMN cortex.engine_features."until" IS 'the last version that has it; NULL for every version to the newest';
COMMENT ON COLUMN cortex.engine_features.detail IS 'what a version alone does not say (enforced from 8.0.16); NULL for nothing';
