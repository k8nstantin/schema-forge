-- workspace.schema_connections: the saved connection a schema is read from, and which database on it.
-- Owner: workspace.
CREATE TABLE workspace.schema_connections (
  id             UUID        NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),  -- UUIDv7
  schema_id      UUID        NOT NULL UNIQUE REFERENCES workspace.workspace_schemas (id) ON DELETE CASCADE,  -- the schema, by its id
  connection_id  UUID        NOT NULL REFERENCES workspace.connections (id) ON DELETE CASCADE,  -- the saved connection it is read from
  database_name  TEXT        NOT NULL CHECK (length(database_name) >= 1),                       -- the database on that server it is read from, as the server names it (shop)
  scope          JSONB       NOT NULL DEFAULT '{"everything": true}',                           -- what is read from it each time (decision read-scope): everything unless the person chose otherwise; a later read asks the same
  created_at     TIMESTAMPTZ NOT NULL                                                           -- when the schema was tied to it
);

COMMENT ON TABLE workspace.schema_connections IS 'the saved connection a schema is read from, and which database on it.';
COMMENT ON COLUMN workspace.schema_connections.id IS 'UUIDv7';
COMMENT ON COLUMN workspace.schema_connections.schema_id IS 'the schema, by its id';
COMMENT ON COLUMN workspace.schema_connections.connection_id IS 'the saved connection it is read from';
COMMENT ON COLUMN workspace.schema_connections.database_name IS 'the database on that server it is read from, as the server names it (shop)';
COMMENT ON COLUMN workspace.schema_connections.scope IS 'what is read from it each time (decision read-scope): everything unless the person chose otherwise; a later read asks the same';
COMMENT ON COLUMN workspace.schema_connections.created_at IS 'when the schema was tied to it';
