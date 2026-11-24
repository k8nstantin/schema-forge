-- schema_migrations: every migration applied to workspace.db. Owner: workspace.
CREATE TABLE schema_migrations (
  id          TEXT    NOT NULL PRIMARY KEY,                                  -- workspace/<version>
  owner       TEXT    NOT NULL CHECK (owner = 'workspace'),                  -- only the workspace's own tables live in this file
  version     INTEGER NOT NULL CHECK (version >= 1),                         -- 1 creates the tables from schema/workspace
  checksum    TEXT    NOT NULL CHECK (length(checksum) = 64),               -- SHA-256 of what was applied, hex
  applied_at  TEXT    NOT NULL,                                              -- UTC, RFC 3339
  UNIQUE (owner, version),
  CHECK (id = owner || '/' || version)
) STRICT;
