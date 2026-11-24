-- cortex.columns: the columns of an object, in order, with what every engine says of a column. Owner: cortex.
CREATE TABLE cortex.columns (
  id                    TEXT    NOT NULL PRIMARY KEY CHECK (id ~ '^c_[a-z0-9_]*$' AND length(id) <= 128),  -- the model's id (c_orders_total), kept when the name changes
  object                TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the object it belongs to
  position              NUMERIC NOT NULL CHECK (position > 0),                              -- its place in the object: 1, 2, 3; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name                  TEXT    NOT NULL CHECK (length(name) >= 1),                         -- total
  type                  TEXT    NOT NULL CHECK (length(type) >= 1),                         -- its type as the engine writes it (decimal(12,2)); only the engine reads it
  nullable              BOOLEAN NOT NULL,                                                   -- true when it may hold null
  comment               TEXT,                                                               -- what it holds: written into its SQL
  default_value         TEXT,                                                               -- its default, an expression in the engine's SQL; NULL for none
  generated_expression  TEXT,                                                               -- the expression it is computed from, in the engine's SQL; NULL when it is not computed
  generated_stored      BOOLEAN,                                                            -- for a computed column: 1 computed when written and stored, 0 computed when read
  UNIQUE (object, position),
  UNIQUE (object, name),
  CHECK ((generated_expression IS NULL) = (generated_stored IS NULL))
);

COMMENT ON TABLE cortex.columns IS 'the columns of an object, in order, with what every engine says of a column.';
COMMENT ON COLUMN cortex.columns.id IS 'the model''s id (c_orders_total), kept when the name changes';
COMMENT ON COLUMN cortex.columns.object IS 'the object it belongs to';
COMMENT ON COLUMN cortex.columns.position IS 'its place in the object: 1, 2, 3; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.columns.name IS 'total';
COMMENT ON COLUMN cortex.columns.type IS 'its type as the engine writes it (decimal(12,2)); only the engine reads it';
COMMENT ON COLUMN cortex.columns.nullable IS 'true when it may hold null';
COMMENT ON COLUMN cortex.columns.comment IS 'what it holds: written into its SQL';
COMMENT ON COLUMN cortex.columns.default_value IS 'its default, an expression in the engine''s SQL; NULL for none';
COMMENT ON COLUMN cortex.columns.generated_expression IS 'the expression it is computed from, in the engine''s SQL; NULL when it is not computed';
COMMENT ON COLUMN cortex.columns.generated_stored IS 'for a computed column: 1 computed when written and stored, 0 computed when read';
