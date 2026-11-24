-- engine_mysql.outside_references: a table's foreign keys to tables outside the schema, each kept exactly as written and written back in its place.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.outside_references (
  id        TEXT    NOT NULL PRIMARY KEY,                                       -- <table>.outside<n>, n given once from id_counters and never reused
  object    TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the table that refers
  position  NUMERIC NOT NULL CHECK (position > 0),                              -- its place among the table's outside references; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  text      TEXT    NOT NULL CHECK (length(text) >= 1),                         -- the constraint, exactly as written
  UNIQUE (object, position),
  CHECK (substr(id, 1, length(object) + 8) = object || '.outside' AND substr(id, length(object) + 9) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_mysql.outside_references IS 'a table''s foreign keys to tables outside the schema, each kept exactly as written and written back in its place. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.outside_references.id IS '<table>.outside<n>, n given once from id_counters and never reused';
COMMENT ON COLUMN engine_mysql.outside_references.object IS 'the table that refers';
COMMENT ON COLUMN engine_mysql.outside_references.position IS 'its place among the table''s outside references; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_mysql.outside_references.text IS 'the constraint, exactly as written';
