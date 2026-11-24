-- workspace.workspace_identity: the workspace this database is, exactly one row. Owner: workspace.
-- The workspace's database (sf_workspace) holds what the workspace shares: the list of its schemas and the saved
-- connections. Each schema is its own database, sf_<its id, hex> (decision 3).
CREATE TABLE workspace.workspace_identity (
  id          UUID        NOT NULL PRIMARY KEY CHECK (uuid_extract_version(id) = 7),  -- UUIDv7, written when the workspace is made
  name        TEXT        NOT NULL CHECK (length(name) BETWEEN 1 AND 100),            -- its name, the name of its folder under ~/.schema-forge/workspaces/
  created_at  TIMESTAMPTZ NOT NULL,                                                   -- when
  one         BOOLEAN     NOT NULL DEFAULT true UNIQUE CHECK (one)                    -- keeps the table to one row
);

COMMENT ON TABLE workspace.workspace_identity IS 'the workspace this database is, exactly one row. The workspace''s database (sf_workspace) holds what the workspace shares: the list of its schemas and the saved connections. Each schema is its own database, sf_<its id, hex> (decision 3).';
COMMENT ON COLUMN workspace.workspace_identity.id IS 'UUIDv7, written when the workspace is made';
COMMENT ON COLUMN workspace.workspace_identity.name IS 'its name, the name of its folder under ~/.schema-forge/workspaces/';
COMMENT ON COLUMN workspace.workspace_identity.created_at IS 'when';
COMMENT ON COLUMN workspace.workspace_identity.one IS 'keeps the table to one row';
