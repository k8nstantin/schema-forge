-- cortex.engine_features: what a version of the database has or lacks (a type, a kind of object, an option, a clause), with the first and last version that has it. Owner: cortex.
CREATE TABLE cortex.engine_features (
  id       TEXT NOT NULL PRIMARY KEY CHECK (id ~ '^[a-z0-9_]+$'),  -- as the engine names it (vector, check_constraints)
  what     TEXT NOT NULL CHECK (length(what) >= 1),                -- what it is, in a few words (the VECTOR type)
  since    TEXT REFERENCES cortex.engine_versions (id),            -- the first version that has it; NULL for every version from the oldest
  "until"  TEXT REFERENCES cortex.engine_versions (id),            -- the last version that has it; NULL for every version to the newest
  detail   TEXT                                                    -- what a version alone does not say (enforced from 8.0.16); NULL for nothing
);

COMMENT ON TABLE cortex.engine_features IS 'what a version of the database has or lacks (a type, a kind of object, an option, a clause), with the first and last version that has it.';
COMMENT ON COLUMN cortex.engine_features.id IS 'as the engine names it (vector, check_constraints)';
COMMENT ON COLUMN cortex.engine_features.what IS 'what it is, in a few words (the VECTOR type)';
COMMENT ON COLUMN cortex.engine_features.since IS 'the first version that has it; NULL for every version from the oldest';
COMMENT ON COLUMN cortex.engine_features."until" IS 'the last version that has it; NULL for every version to the newest';
COMMENT ON COLUMN cortex.engine_features.detail IS 'what a version alone does not say (enforced from 8.0.16); NULL for nothing';
