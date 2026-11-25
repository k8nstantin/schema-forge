-- engine_mysql.object_properties: the options of a table or a tablespace that are not MySQL's core, each as MySQL writes it (decision typed-core).
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
-- Shape 4, open-ended properties: one row per option, its key the option's as MySQL names it (key_block_size), its value as written;
-- an option of a storage engine, of a version, of a cloud or seldom written, so that MySQL adding one never adds a column.
CREATE TABLE engine_mysql.object_properties (
  id        TEXT    NOT NULL PRIMARY KEY,                                       -- <part>.property<n>, n given once from id_counters and never reused: o_orders.property1
  object    TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the part it belongs to
  position  NUMERIC NOT NULL CHECK (position > 0),                              -- its place among the part's options, as written; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  key       TEXT    NOT NULL CHECK (key ~ '^[a-z_]+$'),                         -- the option, as MySQL's options name it (key_block_size)
  value     TEXT    NOT NULL,                                                   -- its value, exactly as written
  UNIQUE (object, key),
  UNIQUE (object, position),
  CHECK (substr(id, 1, length(object) + 9) = object || '.property' AND substr(id, length(object) + 10) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_mysql.object_properties IS 'the options of a table or a tablespace that are not MySQL''s core, each as MySQL writes it (decision typed-core). Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other. Shape 4, open-ended properties: one row per option, its key the option''s as MySQL names it (key_block_size), its value as written; an option of a storage engine, of a version, of a cloud or seldom written, so that MySQL adding one never adds a column.';
COMMENT ON COLUMN engine_mysql.object_properties.id IS '<part>.property<n>, n given once from id_counters and never reused: o_orders.property1';
COMMENT ON COLUMN engine_mysql.object_properties.object IS 'the part it belongs to';
COMMENT ON COLUMN engine_mysql.object_properties.position IS 'its place among the part''s options, as written; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_mysql.object_properties.key IS 'the option, as MySQL''s options name it (key_block_size)';
COMMENT ON COLUMN engine_mysql.object_properties.value IS 'its value, exactly as written';
