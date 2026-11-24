-- workspace.workspace_schemas: every schema of the workspace, each in its own database, by its stable id (decision 4). Owner: workspace.
-- The application keeps it equal to the databases: a database's schema_identity row and its row here have the same id, name and engine.
CREATE TABLE workspace.workspace_schemas (
  id              UUID        NOT NULL PRIMARY KEY CHECK (uuid_extract_version(id) = 7),  -- the schema's id, as its database's schema_identity row holds it; its database is sf_<id, hex>
  name            TEXT        NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 100 AND name ~ '^[A-Za-z0-9-][A-Za-z0-9_.-]*$'),  -- its name; a rename never moves its database
  engine          TEXT        NOT NULL,                                                   -- the id of its engine
  engine_version  TEXT        NOT NULL,                                                   -- the engine version it is designed for
  created_at      TIMESTAMPTZ NOT NULL,                                                   -- when its database was made
  opened_at       TIMESTAMPTZ                                                             -- when it was last opened; NULL if never since it was listed
);

COMMENT ON TABLE workspace.workspace_schemas IS 'every schema of the workspace, each in its own database, by its stable id (decision 4). The application keeps it equal to the databases: a database''s schema_identity row and its row here have the same id, name and engine.';
COMMENT ON COLUMN workspace.workspace_schemas.id IS 'the schema''s id, as its database''s schema_identity row holds it; its database is sf_<id, hex>';
COMMENT ON COLUMN workspace.workspace_schemas.name IS 'its name; a rename never moves its database';
COMMENT ON COLUMN workspace.workspace_schemas.engine IS 'the id of its engine';
COMMENT ON COLUMN workspace.workspace_schemas.engine_version IS 'the engine version it is designed for';
COMMENT ON COLUMN workspace.workspace_schemas.created_at IS 'when its database was made';
COMMENT ON COLUMN workspace.workspace_schemas.opened_at IS 'when it was last opened; NULL if never since it was listed';
