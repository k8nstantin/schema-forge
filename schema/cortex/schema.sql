-- schema: the schema this file holds, exactly one row. Owner: cortex.
-- Written when the file is made; only name, comment and engine_version ever change, each by an operation.
CREATE TABLE schema (
  id              TEXT    NOT NULL PRIMARY KEY CHECK (length(id) = 36 AND substr(id, 15, 1) = '7'),  -- UUIDv7, written when the file is made, never changed: how workspace.db and pipelines name this schema
  name            TEXT    NOT NULL CHECK (length(name) BETWEEN 1 AND 100),                          -- as people call it (shop); the file is schemas/<name>.db
  engine          TEXT    NOT NULL,                                                                 -- the id of the engine it is designed for, as the registry knows it (mysql)
  engine_version  TEXT    NOT NULL,                                                                 -- one of the engine's versions; it decides which features the schema is offered (8.4)
  comment         TEXT,                                                                             -- what the schema is for, in a sentence or two
  section_format  INTEGER NOT NULL DEFAULT 0 CHECK (section_format >= 0),                           -- the engine's storage version its options were written in, as the schema's section holds it (0 when it says none)
  created_at      TEXT    NOT NULL CHECK (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*Z'),  -- when the file was made, UTC, RFC 3339
  one             INTEGER NOT NULL DEFAULT 1 UNIQUE CHECK (one = 1)                                 -- keeps the table to one row
) STRICT;
