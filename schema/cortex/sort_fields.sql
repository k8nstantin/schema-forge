-- cortex.sort_fields: the order a table's rows are written in (a sort order, a clustering). Owner: cortex.
CREATE TABLE cortex.sort_fields (
  id         TEXT    NOT NULL PRIMARY KEY,                                       -- <object>.order<n>, n given once from id_counters and never reused: o_events.order1
  object     TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the table
  position   NUMERIC NOT NULL CHECK (position > 0),                              -- its place in the order; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  "column"   TEXT    NOT NULL REFERENCES cortex.columns (id) ON DELETE CASCADE,  -- the column ordered by
  transform  TEXT,                                                               -- the transform, in the engine's words; NULL for the value itself
  direction  TEXT    CHECK (direction IN ('asc', 'desc')),                       -- NULL for the engine's default
  nulls      TEXT    CHECK (nulls IN ('first', 'last')),                         -- NULL for the engine's default
  UNIQUE (object, position),
  CHECK (substr(id, 1, length(object) + 6) = object || '.order' AND substr(id, length(object) + 7) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.sort_fields IS 'the order a table''s rows are written in (a sort order, a clustering).';
COMMENT ON COLUMN cortex.sort_fields.id IS '<object>.order<n>, n given once from id_counters and never reused: o_events.order1';
COMMENT ON COLUMN cortex.sort_fields.object IS 'the table';
COMMENT ON COLUMN cortex.sort_fields.position IS 'its place in the order; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.sort_fields."column" IS 'the column ordered by';
COMMENT ON COLUMN cortex.sort_fields.transform IS 'the transform, in the engine''s words; NULL for the value itself';
COMMENT ON COLUMN cortex.sort_fields.direction IS 'NULL for the engine''s default';
COMMENT ON COLUMN cortex.sort_fields.nulls IS 'NULL for the engine''s default';
