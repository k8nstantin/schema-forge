-- cortex.enum_values: the values of an enumerated type, in order. Owner: cortex.
CREATE TABLE cortex.enum_values (
  id        TEXT    NOT NULL PRIMARY KEY,                                       -- <object>.value<n>, n given once from id_counters and never reused: o_order_status.value1
  object    TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the type
  position  NUMERIC NOT NULL CHECK (position > 0),                              -- its place among the values; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  value     TEXT    NOT NULL,                                                   -- the value
  UNIQUE (object, position),
  UNIQUE (object, value),
  CHECK (substr(id, 1, length(object) + 6) = object || '.value' AND substr(id, length(object) + 7) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.enum_values IS 'the values of an enumerated type, in order.';
COMMENT ON COLUMN cortex.enum_values.id IS '<object>.value<n>, n given once from id_counters and never reused: o_order_status.value1';
COMMENT ON COLUMN cortex.enum_values.object IS 'the type';
COMMENT ON COLUMN cortex.enum_values.position IS 'its place among the values; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.enum_values.value IS 'the value';
