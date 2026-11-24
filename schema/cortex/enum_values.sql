-- enum_values: the values of an enumerated type, in order. Owner: cortex.
CREATE TABLE enum_values (
  id        TEXT    NOT NULL PRIMARY KEY,                                      -- <object>.value<position>: o_order_status.value1
  object    TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,        -- the type
  position  INTEGER NOT NULL CHECK (position >= 1),                            -- its place among the values
  value     TEXT    NOT NULL,                                                  -- the value
  UNIQUE (object, position),
  UNIQUE (object, value),
  CHECK (id = object || '.value' || position)
) STRICT;
