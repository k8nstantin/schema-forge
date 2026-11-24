-- cortex.catalog_sources: what the engine's live read asks a server of each version, what it gives, and the grant it needs.
-- Written when the database is made, from the engine's declaration (decision version-facts): what the Connections page shows
-- and the connection test checks, so a missing grant says what will not be read.
-- Owner: cortex.
CREATE TABLE cortex.catalog_sources (
  id        TEXT    NOT NULL PRIMARY KEY,                                       -- <version>/<source>: 5.7/information_schema.ROUTINES
  version   TEXT    NOT NULL REFERENCES cortex.engine_versions (id),            -- the version it is asked of
  source    TEXT    NOT NULL CHECK (length(source) >= 1),                       -- the catalog table or statement, as the server names it (performance_schema.table_io_waits_summary_by_table, SHOW CREATE TABLE)
  gives     TEXT    NOT NULL CHECK (length(gives) >= 1),                        -- what the read takes from it (routines and their bodies)
  needs     TEXT,                                                               -- the grant it needs, as the server writes it (SELECT ON mysql.proc); NULL for none beyond the database's
  usage     BOOLEAN NOT NULL DEFAULT false,                                     -- true for a source of usage (performance_schema), false for one of structure
  position  NUMERIC NOT NULL CHECK (position > 0),                              -- its place in the read of its version, in the order asked
  UNIQUE (version, source),
  UNIQUE (version, position),
  CHECK (id = version || '/' || source)
);

COMMENT ON TABLE cortex.catalog_sources IS 'what the engine''s live read asks a server of each version, what it gives, and the grant it needs. Written when the database is made, from the engine''s declaration (decision version-facts): what the Connections page shows and the connection test checks, so a missing grant says what will not be read.';
COMMENT ON COLUMN cortex.catalog_sources.id IS '<version>/<source>: 5.7/information_schema.ROUTINES';
COMMENT ON COLUMN cortex.catalog_sources.version IS 'the version it is asked of';
COMMENT ON COLUMN cortex.catalog_sources.source IS 'the catalog table or statement, as the server names it (performance_schema.table_io_waits_summary_by_table, SHOW CREATE TABLE)';
COMMENT ON COLUMN cortex.catalog_sources.gives IS 'what the read takes from it (routines and their bodies)';
COMMENT ON COLUMN cortex.catalog_sources.needs IS 'the grant it needs, as the server writes it (SELECT ON mysql.proc); NULL for none beyond the database''s';
COMMENT ON COLUMN cortex.catalog_sources.usage IS 'true for a source of usage (performance_schema), false for one of structure';
COMMENT ON COLUMN cortex.catalog_sources.position IS 'its place in the read of its version, in the order asked';
