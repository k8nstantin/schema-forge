-- mysql__outside_references: a table's foreign keys to tables outside the schema, each kept exactly as written and written back in its place.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__outside_references (
  id        TEXT    NOT NULL PRIMARY KEY,                                    -- <table>.outside<position>
  object    TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,      -- the table that refers
  position  INTEGER NOT NULL CHECK (position >= 1),                          -- its place among the table's outside references
  text      TEXT    NOT NULL CHECK (length(text) >= 1),                      -- the constraint, exactly as written
  UNIQUE (object, position),
  CHECK (id = object || '.outside' || position)
) STRICT;
