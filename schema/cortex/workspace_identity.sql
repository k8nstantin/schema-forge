-- cortex.workspace_identity: the workspace this database is, exactly one row: its saved connections and every design are in this database. Owner: cortex.
CREATE TABLE cortex.workspace_identity (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),  -- UUIDv7, written when the workspace is made
  name        TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),                             -- its name, the name of its folder under ~/.schema-forge/workspaces/
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),                                               -- when
  one         BOOLEAN NOT NULL DEFAULT true UNIQUE CHECK (one)                                  -- keeps the table to one row
);

COMMENT ON TABLE cortex.workspace_identity IS 'the workspace this database is, exactly one row: its saved connections and every design are in this database.';
COMMENT ON COLUMN cortex.workspace_identity.id IS 'UUIDv7, written when the workspace is made';
COMMENT ON COLUMN cortex.workspace_identity.name IS 'its name, the name of its folder under ~/.schema-forge/workspaces/';
COMMENT ON COLUMN cortex.workspace_identity.created_at IS 'when';
COMMENT ON COLUMN cortex.workspace_identity.one IS 'keeps the table to one row';
