-- cortex.table_keys: a table's primary key, its unique keys and its identifier fields. Owner: cortex.
CREATE TABLE cortex.table_keys (
  id        TEXT    NOT NULL PRIMARY KEY,                                          -- <object>.key<n>, n given once from id_counters and never reused: o_orders.key1
  object    TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,     -- the table it is on
  position  NUMERIC NOT NULL CHECK (position > 0),                                 -- its place among the table's keys: the primary key first; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  what      TEXT    NOT NULL CHECK (what IN ('primary', 'unique', 'identifier')),  -- primary, unique, or identifier: columns that identify a row with no constraint enforcing it
  name      TEXT,                                                                  -- its constraint name; NULL for none
  UNIQUE (object, position),
  CHECK (substr(id, 1, length(object) + 4) = object || '.key' AND substr(id, length(object) + 5) ~ '^[1-9][0-9]*$')
);
CREATE UNIQUE INDEX table_keys_one_primary ON cortex.table_keys (object) WHERE what = 'primary';

COMMENT ON TABLE cortex.table_keys IS 'a table''s primary key, its unique keys and its identifier fields.';
COMMENT ON COLUMN cortex.table_keys.id IS '<object>.key<n>, n given once from id_counters and never reused: o_orders.key1';
COMMENT ON COLUMN cortex.table_keys.object IS 'the table it is on';
COMMENT ON COLUMN cortex.table_keys.position IS 'its place among the table''s keys: the primary key first; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.table_keys.what IS 'primary, unique, or identifier: columns that identify a row with no constraint enforcing it';
COMMENT ON COLUMN cortex.table_keys.name IS 'its constraint name; NULL for none';
