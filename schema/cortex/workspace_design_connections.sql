-- cortex.workspace_design_connections: the saved connection a design is read from, which database on it, and what is read each time. Owner: cortex.
CREATE TABLE cortex.workspace_design_connections (
  id             UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                             -- UUIDv7
  design         UUID NOT NULL UNIQUE REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,         -- the design
  connection     UUID NOT NULL REFERENCES cortex.workspace_connections (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the saved connection it is read from
  database_name  TEXT NOT NULL CHECK (length(database_name) >= 1),                                                            -- the database on that server it is read from, as the server names it (shop)
  scope          JSONB NOT NULL DEFAULT '{"everything": true}',                                                               -- what is read from it each time (decision read-scope): everything unless the person chose parts, kinds or objects
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()                                                                           -- when the design was tied to it
);

COMMENT ON TABLE cortex.workspace_design_connections IS 'the saved connection a design is read from, which database on it, and what is read each time.';
COMMENT ON COLUMN cortex.workspace_design_connections.id IS 'UUIDv7';
COMMENT ON COLUMN cortex.workspace_design_connections.design IS 'the design';
COMMENT ON COLUMN cortex.workspace_design_connections.connection IS 'the saved connection it is read from';
COMMENT ON COLUMN cortex.workspace_design_connections.database_name IS 'the database on that server it is read from, as the server names it (shop)';
COMMENT ON COLUMN cortex.workspace_design_connections.scope IS 'what is read from it each time (decision read-scope): everything unless the person chose parts, kinds or objects';
COMMENT ON COLUMN cortex.workspace_design_connections.created_at IS 'when the design was tied to it';
