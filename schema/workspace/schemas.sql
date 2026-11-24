-- schemas: every schema of the workspace, each in its own file, by its stable id (decision 4). Owner: workspace.
-- The application keeps it equal to the files: a file's schema row and its row here have the same id, name and engine.
CREATE TABLE schemas (
  id              TEXT  NOT NULL PRIMARY KEY CHECK (length(id) = 36 AND substr(id, 15, 1) = '7'),  -- the schema's id, as its file's schema row holds it
  name            TEXT  NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 100 AND name NOT GLOB '*[^A-Za-z0-9_.-]*' AND name NOT GLOB '[._]*'),  -- its name; its file is schemas/<name>.db
  engine          TEXT  NOT NULL,                                              -- the id of its engine
  engine_version  TEXT  NOT NULL,                                              -- the engine version it is designed for
  created_at      TEXT  NOT NULL,                                              -- when its file was made, UTC, RFC 3339
  opened_at       TEXT                                                         -- when it was last opened, UTC, RFC 3339; NULL if never since it was listed
) STRICT;
