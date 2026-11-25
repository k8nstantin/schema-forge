-- engine_mysql.key_properties: the options of a primary or unique key that are not MySQL's core, each as MySQL writes it (decision typed-core).
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
-- Shape 4, open-ended properties: one row per option, its key the option's as MySQL names it (key_block_size), its value as written;
-- an option of a storage engine, of a version, of a cloud or seldom written, so that MySQL adding one never adds a column.
CREATE TABLE engine_mysql.key_properties (
  id         TEXT    NOT NULL PRIMARY KEY,                                          -- <part>.property<n>, n given once from id_counters and never reused: o_orders.key1.property1
  table_key  TEXT    NOT NULL REFERENCES cortex.table_keys (id) ON DELETE CASCADE,  -- the part it belongs to
  position   NUMERIC NOT NULL CHECK (position > 0),                                 -- its place among the part's options, as written; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  key        TEXT    NOT NULL CHECK (key ~ '^[a-z_]+$'),                            -- the option, as MySQL's options name it (key_block_size)
  value      TEXT    NOT NULL,                                                      -- its value, exactly as written
  UNIQUE (table_key, key),
  UNIQUE (table_key, position),
  CHECK (substr(id, 1, length(table_key) + 9) = table_key || '.property' AND substr(id, length(table_key) + 10) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_mysql.key_properties IS 'the options of a primary or unique key that are not MySQL''s core, each as MySQL writes it (decision typed-core). Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other. Shape 4, open-ended properties: one row per option, its key the option''s as MySQL names it (key_block_size), its value as written; an option of a storage engine, of a version, of a cloud or seldom written, so that MySQL adding one never adds a column.';
COMMENT ON COLUMN engine_mysql.key_properties.id IS '<part>.property<n>, n given once from id_counters and never reused: o_orders.key1.property1';
COMMENT ON COLUMN engine_mysql.key_properties.table_key IS 'the part it belongs to';
COMMENT ON COLUMN engine_mysql.key_properties.position IS 'its place among the part''s options, as written; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_mysql.key_properties.key IS 'the option, as MySQL''s options name it (key_block_size)';
COMMENT ON COLUMN engine_mysql.key_properties.value IS 'its value, exactly as written';
