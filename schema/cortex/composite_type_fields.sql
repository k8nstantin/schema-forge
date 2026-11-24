-- cortex.composite_type_fields: the fields of a composite type, in order. Owner: cortex.
CREATE TABLE cortex.composite_type_fields (
  id        TEXT    NOT NULL PRIMARY KEY,                                       -- <object>.field<n>, n given once from id_counters and never reused: o_address.field1
  object    TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the type
  position  NUMERIC NOT NULL CHECK (position > 0),                              -- its place in the type; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name      TEXT    NOT NULL CHECK (length(name) >= 1),                         -- its name
  type      TEXT    NOT NULL CHECK (length(type) >= 1),                         -- its type, as the engine writes it
  comment   TEXT,                                                               -- what it holds
  UNIQUE (object, position),
  UNIQUE (object, name),
  CHECK (substr(id, 1, length(object) + 6) = object || '.field' AND substr(id, length(object) + 7) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.composite_type_fields IS 'the fields of a composite type, in order.';
COMMENT ON COLUMN cortex.composite_type_fields.id IS '<object>.field<n>, n given once from id_counters and never reused: o_address.field1';
COMMENT ON COLUMN cortex.composite_type_fields.object IS 'the type';
COMMENT ON COLUMN cortex.composite_type_fields.position IS 'its place in the type; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.composite_type_fields.name IS 'its name';
COMMENT ON COLUMN cortex.composite_type_fields.type IS 'its type, as the engine writes it';
COMMENT ON COLUMN cortex.composite_type_fields.comment IS 'what it holds';
