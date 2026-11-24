-- connections: a saved connection to a live database: a name and an engine; its values are in connection_values, never its secret (docs/connections.md). Owner: workspace.
CREATE TABLE connections (
  id          TEXT  NOT NULL PRIMARY KEY CHECK (length(id) = 36 AND substr(id, 15, 1) = '7'),  -- UUIDv7
  name        TEXT  NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 100 AND name NOT GLOB '*[^A-Za-z0-9_.-]*' AND name NOT GLOB '[._]*'),  -- as people call it (prod-replica)
  engine      TEXT  NOT NULL,                                                  -- the id of the engine whose fields it fills
  created_at  TEXT  NOT NULL                                                   -- UTC, RFC 3339
) STRICT;
