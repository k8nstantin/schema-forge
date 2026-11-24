-- cortex.object_reads: the objects an object is made from or reads (a view's query), worked out by the engine, in the order first named. Owner: cortex.
CREATE TABLE cortex.object_reads (
  id        TEXT    NOT NULL PRIMARY KEY,                                       -- <object>.read<n>, n given once from id_counters and never reused: o_current_orders.read1
  object    TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the object that reads
  position  NUMERIC NOT NULL CHECK (position > 0),                              -- the order the reader names them in; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  reads     TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the object read
  UNIQUE (object, position),
  UNIQUE (object, reads),
  CHECK (object <> reads),
  CHECK (substr(id, 1, length(object) + 5) = object || '.read' AND substr(id, length(object) + 6) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.object_reads IS 'the objects an object is made from or reads (a view''s query), worked out by the engine, in the order first named.';
COMMENT ON COLUMN cortex.object_reads.id IS '<object>.read<n>, n given once from id_counters and never reused: o_current_orders.read1';
COMMENT ON COLUMN cortex.object_reads.object IS 'the object that reads';
COMMENT ON COLUMN cortex.object_reads.position IS 'the order the reader names them in; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.object_reads.reads IS 'the object read';
