-- keys: a table's primary key, its unique keys and its identifier fields. Owner: cortex.
CREATE TABLE keys (
  id        TEXT    NOT NULL PRIMARY KEY,                                      -- <object>.key<position>: o_orders.key1
  object    TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,        -- the table it is on
  position  INTEGER NOT NULL CHECK (position >= 1),                            -- its place among the table's keys: the primary key first
  what      TEXT    NOT NULL CHECK (what IN ('primary', 'unique', 'identifier')),  -- primary, unique, or identifier: columns that identify a row with no constraint enforcing it
  name      TEXT,                                                              -- its constraint name; NULL for none
  UNIQUE (object, position),
  CHECK (id = object || '.key' || position)
) STRICT;
CREATE UNIQUE INDEX keys_one_primary ON keys (object) WHERE what = 'primary';
