-- cortex.table_key_columns: the columns of a key, in order. Owner: cortex.
CREATE TABLE cortex.table_key_columns (
  id        TEXT    NOT NULL PRIMARY KEY,                                          -- <key>.<n>, n given once from id_counters and never reused: o_orders.key1.1
  key       TEXT    NOT NULL REFERENCES cortex.table_keys (id) ON DELETE CASCADE,  -- the key
  position  NUMERIC NOT NULL CHECK (position > 0),                                 -- the column's place in the key; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  "column"  TEXT    NOT NULL REFERENCES cortex.columns (id) ON DELETE CASCADE,     -- a column of the key's table
  UNIQUE (key, position),
  UNIQUE (key, "column"),
  CHECK (substr(id, 1, length(key) + 1) = key || '.' AND substr(id, length(key) + 2) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.table_key_columns IS 'the columns of a key, in order.';
COMMENT ON COLUMN cortex.table_key_columns.id IS '<key>.<n>, n given once from id_counters and never reused: o_orders.key1.1';
COMMENT ON COLUMN cortex.table_key_columns.key IS 'the key';
COMMENT ON COLUMN cortex.table_key_columns.position IS 'the column''s place in the key; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.table_key_columns."column" IS 'a column of the key''s table';
