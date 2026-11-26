-- cortex.workspace_connections: a saved connection to a live database: a name and an engine; its values are in workspace_connection_values, never its secret. Owner: cortex.
CREATE TABLE cortex.workspace_connections (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                         -- UUIDv7
  name        TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 100 AND name ~ '^[A-Za-z0-9-][A-Za-z0-9_.-]*$'),  -- as people call it (prod-replica)
  engine      TEXT NOT NULL,                                                                                           -- the id of the engine whose fields it fills
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()                                                                       -- when
);

COMMENT ON TABLE cortex.workspace_connections IS 'a saved connection to a live database: a name and an engine; its values are in workspace_connection_values, never its secret.';
COMMENT ON COLUMN cortex.workspace_connections.id IS 'UUIDv7';
COMMENT ON COLUMN cortex.workspace_connections.name IS 'as people call it (prod-replica)';
COMMENT ON COLUMN cortex.workspace_connections.engine IS 'the id of the engine whose fields it fills';
COMMENT ON COLUMN cortex.workspace_connections.created_at IS 'when';
