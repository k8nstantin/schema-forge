-- cortex.engine_versions: the versions of the database the schema's engine supports, in order, as the engine declares them.
-- Written when the database is made, from the engine's declaration (decision version-facts); the engine's code is the one source.
-- Owner: cortex.
CREATE TABLE cortex.engine_versions (
  id            TEXT        NOT NULL PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 40),  -- as the engine names the version (5.7, 8.4)
  name          TEXT        NOT NULL CHECK (length(name) >= 1),                        -- as people say it (MySQL 8.4)
  position      NUMERIC     NOT NULL UNIQUE CHECK (position > 0),                      -- its place, oldest first: a version's features compare by it
  support_ends  TIMESTAMPTZ                                                            -- when its maker stops supporting it; NULL when not announced
);

COMMENT ON TABLE cortex.engine_versions IS 'the versions of the database the schema''s engine supports, in order, as the engine declares them. Written when the database is made, from the engine''s declaration (decision version-facts); the engine''s code is the one source.';
COMMENT ON COLUMN cortex.engine_versions.id IS 'as the engine names the version (5.7, 8.4)';
COMMENT ON COLUMN cortex.engine_versions.name IS 'as people say it (MySQL 8.4)';
COMMENT ON COLUMN cortex.engine_versions.position IS 'its place, oldest first: a version''s features compare by it';
COMMENT ON COLUMN cortex.engine_versions.support_ends IS 'when its maker stops supporting it; NULL when not announced';
