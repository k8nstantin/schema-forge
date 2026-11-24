-- engine_mysql.view_column_names: the names a view gives its columns (CREATE VIEW v (a, b) AS ...), in order.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.view_column_names (
  id        TEXT    NOT NULL PRIMARY KEY,                                                  -- <view>.name<n>, n given once from id_counters and never reused
  object    TEXT    NOT NULL REFERENCES engine_mysql.view_options (id) ON DELETE CASCADE,  -- the view
  position  NUMERIC NOT NULL CHECK (position > 0),                                         -- its place in the list; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name      TEXT    NOT NULL CHECK (length(name) >= 1),                                    -- the column name
  UNIQUE (object, position),
  CHECK (substr(id, 1, length(object) + 5) = object || '.name' AND substr(id, length(object) + 6) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_mysql.view_column_names IS 'the names a view gives its columns (CREATE VIEW v (a, b) AS ...), in order. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.view_column_names.id IS '<view>.name<n>, n given once from id_counters and never reused';
COMMENT ON COLUMN engine_mysql.view_column_names.object IS 'the view';
COMMENT ON COLUMN engine_mysql.view_column_names.position IS 'its place in the list; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_mysql.view_column_names.name IS 'the column name';
