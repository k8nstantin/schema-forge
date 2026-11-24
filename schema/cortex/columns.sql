-- columns: the columns of an object, in order, with what every engine says of a column. Owner: cortex.
CREATE TABLE columns (
  id                    TEXT    NOT NULL PRIMARY KEY CHECK (id GLOB 'c_*' AND id NOT GLOB '*[^a-z0-9_]*' AND length(id) <= 128),  -- the model's id (c_orders_total), kept when the name changes
  object                TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,  -- the object it belongs to
  position              INTEGER NOT NULL CHECK (position >= 1),                    -- its place in the object: 1, 2, 3
  name                  TEXT    NOT NULL CHECK (length(name) >= 1),                -- total
  type                  TEXT    NOT NULL CHECK (length(type) >= 1),                -- its type as the engine writes it (decimal(12,2)); only the engine reads it
  nullable              INTEGER NOT NULL CHECK (nullable IN (0, 1)),               -- 1 when it may hold null
  comment               TEXT,                                                      -- what it holds: written into its SQL
  default_value         TEXT,                                                      -- its default, an expression in the engine's SQL; NULL for none
  generated_expression  TEXT,                                                      -- the expression it is computed from, in the engine's SQL; NULL when it is not computed
  generated_stored      INTEGER CHECK (generated_stored IN (0, 1)),                -- for a computed column: 1 computed when written and stored, 0 computed when read
  UNIQUE (object, position),
  UNIQUE (object, name),
  CHECK ((generated_expression IS NULL) = (generated_stored IS NULL))
) STRICT;
