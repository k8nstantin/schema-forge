-- workspace.schema_migrations: every migration applied to workspace.db. Owner: workspace.
CREATE TABLE workspace.schema_migrations (
  id          TEXT        NOT NULL PRIMARY KEY,                                 -- workspace/<version>
  owner       TEXT        NOT NULL CHECK (owner = 'workspace'),                 -- only the workspace's own tables live in this database
  version     INTEGER     NOT NULL CHECK (version >= 1),                        -- 1 creates the tables from schema/workspace
  checksum    TEXT        NOT NULL CHECK (length(checksum) = 64),               -- SHA-256 of what was applied, hex
  applied_at  TIMESTAMPTZ NOT NULL,                                             -- when
  UNIQUE (owner, version),
  CHECK (id = owner || '/' || version)
);

COMMENT ON TABLE workspace.schema_migrations IS 'every migration applied to workspace.db.';
COMMENT ON COLUMN workspace.schema_migrations.id IS 'workspace/<version>';
COMMENT ON COLUMN workspace.schema_migrations.owner IS 'only the workspace''s own tables live in this database';
COMMENT ON COLUMN workspace.schema_migrations.version IS '1 creates the tables from schema/workspace';
COMMENT ON COLUMN workspace.schema_migrations.checksum IS 'SHA-256 of what was applied, hex';
COMMENT ON COLUMN workspace.schema_migrations.applied_at IS 'when';
