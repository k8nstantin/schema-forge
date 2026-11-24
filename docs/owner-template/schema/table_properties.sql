-- engine_example.table_properties: a table's free properties (WITH PROPERTIES ('k' = 'v')), each kept as written. Owner: example.
-- Shape 4, open-ended properties: for what the engine lets anyone name; one row per key, the key and the value as written.
-- Use it only when the engine itself has no fixed list: a property the engine names belongs in a typed column of shape 1.
CREATE TABLE engine_example.table_properties (
  id        TEXT    NOT NULL PRIMARY KEY,                                       -- <object>.property<n>, n given once from id_counters and never reused: o_orders.property1
  object    TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the table
  position  NUMERIC NOT NULL CHECK (position > 0),                              -- its place as written; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  key       TEXT    NOT NULL CHECK (length(key) >= 1),                          -- the property's key, as written
  value     TEXT    NOT NULL,                                                   -- its value, as written
  UNIQUE (object, key),
  UNIQUE (object, position),
  CHECK (substr(id, 1, length(object) + 9) = object || '.property' AND substr(id, length(object) + 10) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_example.table_properties IS 'a table''s free properties (WITH PROPERTIES (''k'' = ''v'')), each kept as written. Shape 4, open-ended properties: for what the engine lets anyone name; one row per key, the key and the value as written. Use it only when the engine itself has no fixed list: a property the engine names belongs in a typed column of shape 1.';
COMMENT ON COLUMN engine_example.table_properties.id IS '<object>.property<n>, n given once from id_counters and never reused: o_orders.property1';
COMMENT ON COLUMN engine_example.table_properties.object IS 'the table';
COMMENT ON COLUMN engine_example.table_properties.position IS 'its place as written; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_example.table_properties.key IS 'the property''s key, as written';
COMMENT ON COLUMN engine_example.table_properties.value IS 'its value, as written';
