-- namespaces: the levels that hold objects, nested under another or at the top. Owner: cortex.
-- What the engine calls one (a database, a schema, a shelf) is the engine's word, never stored here.
CREATE TABLE namespaces (
  id        TEXT    NOT NULL PRIMARY KEY CHECK (id GLOB 'n_*' AND id NOT GLOB '*[^a-z0-9_]*' AND length(id) <= 128),  -- the model's id (n_sales), kept when the name changes
  name      TEXT    NOT NULL CHECK (length(name) >= 1),                       -- sales
  parent    TEXT    REFERENCES namespaces (id) ON DELETE CASCADE,             -- the namespace it sits in; NULL at the top
  position  INTEGER NOT NULL CHECK (position >= 1),                            -- its place among the namespaces, in the order they were made or read
  comment   TEXT,                                                              -- what it holds
  UNIQUE (parent, name),
  UNIQUE (position)
) STRICT;
