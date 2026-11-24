-- mysql__view_column_names: the names a view gives its columns (CREATE VIEW v (a, b) AS ...), in order.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__view_column_names (
  id        TEXT    NOT NULL PRIMARY KEY,                                    -- <view>.name<position>
  object    TEXT    NOT NULL REFERENCES mysql__view_options (id) ON DELETE CASCADE,  -- the view
  position  INTEGER NOT NULL CHECK (position >= 1),                          -- its place in the list
  name      TEXT    NOT NULL CHECK (length(name) >= 1),                      -- the column name
  UNIQUE (object, position),
  CHECK (id = object || '.name' || position)
) STRICT;
