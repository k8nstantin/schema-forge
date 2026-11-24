-- workspace: the workspace this file is, exactly one row. Owner: workspace.
-- workspace.db holds what the workspace shares: the list of its schemas and the saved connections. Each schema is its
-- own file, schemas/<name>.db (decision 3).
CREATE TABLE workspace (
  id          TEXT    NOT NULL PRIMARY KEY CHECK (length(id) = 36 AND substr(id, 15, 1) = '7'),  -- UUIDv7, written when the workspace is made
  name        TEXT    NOT NULL CHECK (length(name) BETWEEN 1 AND 100),         -- its name, the name of its folder under ~/.schema-forge/workspaces/
  created_at  TEXT    NOT NULL,                                                -- UTC, RFC 3339
  one         INTEGER NOT NULL DEFAULT 1 UNIQUE CHECK (one = 1)                -- keeps the table to one row
) STRICT;
