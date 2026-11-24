-- workspace.connections: a saved connection to a live database: a name and an engine; its values are in connection_values, never its secret (docs/connections.xml). Owner: workspace.
CREATE TABLE workspace.connections (
  id          UUID        NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),  -- UUIDv7
  name        TEXT        NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 100 AND name ~ '^[A-Za-z0-9-][A-Za-z0-9_.-]*$'),  -- as people call it (prod-replica)
  engine      TEXT        NOT NULL,                                             -- the id of the engine whose fields it fills
  created_at  TIMESTAMPTZ NOT NULL                                              -- when
);

COMMENT ON TABLE workspace.connections IS 'a saved connection to a live database: a name and an engine; its values are in connection_values, never its secret (docs/connections.xml).';
COMMENT ON COLUMN workspace.connections.id IS 'UUIDv7';
COMMENT ON COLUMN workspace.connections.name IS 'as people call it (prod-replica)';
COMMENT ON COLUMN workspace.connections.engine IS 'the id of the engine whose fields it fills';
COMMENT ON COLUMN workspace.connections.created_at IS 'when';
