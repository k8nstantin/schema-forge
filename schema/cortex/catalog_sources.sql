-- cortex.catalog_sources: what an engine's live read asks a server of each version, what it gives, and the grant it needs. Owner: cortex.
CREATE TABLE cortex.catalog_sources (
  id        TEXT NOT NULL PRIMARY KEY,                                                                         -- <engine>/<version>/<source>: mysql/8.4/information_schema.ROUTINES
  version   TEXT NOT NULL REFERENCES cortex.engine_versions (id),                                              -- the engine's version it is asked of (mysql/8.4)
  source    TEXT NOT NULL CHECK (length(source) >= 1),                                                         -- the catalog table or statement, as the server names it (SHOW CREATE TABLE)
  gives     TEXT NOT NULL CHECK (length(gives) >= 1),                                                          -- what the read takes from it (routines and their bodies)
  needs     TEXT,                                                                                              -- the grant it needs, as the server writes it; NULL for none beyond the database's
  part      TEXT NOT NULL DEFAULT 'definition' CHECK (part IN ('definition', 'metadata', 'usage', 'server')),  -- what it gives: definition, the objects and their definitions (1.0); metadata, usage and server are 2.0's, read only by 2.0's owners (decision definitions-first)
  position  NUMERIC NOT NULL CHECK (position > 0),                                                             -- its place in the read of its version, in the order asked
  UNIQUE (version, source),
  UNIQUE (version, position),
  CHECK (id = version || '/' || source)
);

COMMENT ON TABLE cortex.catalog_sources IS 'what an engine''s live read asks a server of each version, what it gives, and the grant it needs.';
COMMENT ON COLUMN cortex.catalog_sources.id IS '<engine>/<version>/<source>: mysql/8.4/information_schema.ROUTINES';
COMMENT ON COLUMN cortex.catalog_sources.version IS 'the engine''s version it is asked of (mysql/8.4)';
COMMENT ON COLUMN cortex.catalog_sources.source IS 'the catalog table or statement, as the server names it (SHOW CREATE TABLE)';
COMMENT ON COLUMN cortex.catalog_sources.gives IS 'what the read takes from it (routines and their bodies)';
COMMENT ON COLUMN cortex.catalog_sources.needs IS 'the grant it needs, as the server writes it; NULL for none beyond the database''s';
COMMENT ON COLUMN cortex.catalog_sources.part IS 'what it gives: definition, the objects and their definitions (1.0); metadata, usage and server are 2.0''s, read only by 2.0''s owners (decision definitions-first)';
COMMENT ON COLUMN cortex.catalog_sources.position IS 'its place in the read of its version, in the order asked';
