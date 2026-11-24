-- key_columns: the columns of a key, in order. Owner: cortex.
CREATE TABLE key_columns (
  id        TEXT    NOT NULL PRIMARY KEY,                                      -- <key>.<position>: o_orders.key1.1
  key       TEXT    NOT NULL REFERENCES keys (id) ON DELETE CASCADE,           -- the key
  position  INTEGER NOT NULL CHECK (position >= 1),                            -- the column's place in the key
  "column"  TEXT    NOT NULL REFERENCES columns (id) ON DELETE CASCADE,        -- a column of the key's table
  UNIQUE (key, position),
  UNIQUE (key, "column"),
  CHECK (id = key || '.' || position)
) STRICT;
