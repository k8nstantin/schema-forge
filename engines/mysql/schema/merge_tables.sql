-- engine_mysql.merge_tables: the tables a MERGE table joins (UNION=(...)), in order, each as written.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.merge_tables (
  id          TEXT    NOT NULL PRIMARY KEY,                                                   -- <table>.merge<n>, n given once from id_counters and never reused
  object      TEXT    NOT NULL REFERENCES engine_mysql.table_options (id) ON DELETE CASCADE,  -- the MERGE table
  position    NUMERIC NOT NULL CHECK (position > 0),                                          -- its place in UNION; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  table_name  TEXT    NOT NULL CHECK (length(table_name) >= 1),                               -- the joined table's name as written (it may be outside the schema)
  UNIQUE (object, position),
  CHECK (substr(id, 1, length(object) + 6) = object || '.merge' AND substr(id, length(object) + 7) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_mysql.merge_tables IS 'the tables a MERGE table joins (UNION=(...)), in order, each as written. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.merge_tables.id IS '<table>.merge<n>, n given once from id_counters and never reused';
COMMENT ON COLUMN engine_mysql.merge_tables.object IS 'the MERGE table';
COMMENT ON COLUMN engine_mysql.merge_tables.position IS 'its place in UNION; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_mysql.merge_tables.table_name IS 'the joined table''s name as written (it may be outside the schema)';
