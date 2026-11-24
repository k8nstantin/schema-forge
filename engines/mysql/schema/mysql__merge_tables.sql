-- mysql__merge_tables: the tables a MERGE table joins (UNION=(...)), in order, each as written.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__merge_tables (
  id          TEXT    NOT NULL PRIMARY KEY,                                  -- <table>.merge<position>
  object      TEXT    NOT NULL REFERENCES mysql__table_options (id) ON DELETE CASCADE,  -- the MERGE table
  position    INTEGER NOT NULL CHECK (position >= 1),                        -- its place in UNION
  table_name  TEXT    NOT NULL CHECK (length(table_name) >= 1),              -- the joined table's name as written (it may be outside the schema)
  UNIQUE (object, position),
  CHECK (id = object || '.merge' || position)
) STRICT;
