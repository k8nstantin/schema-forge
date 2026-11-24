-- cortex.partition_fields: what a table is partitioned by, in order: a column or an expression, through a transform. Owner: cortex.
CREATE TABLE cortex.partition_fields (
  id            TEXT    NOT NULL PRIMARY KEY,                                                   -- <object>.by<n>, n given once from id_counters and never reused: o_events.by1
  partitioning  TEXT    NOT NULL REFERENCES cortex.table_partitionings (id) ON DELETE CASCADE,  -- the partitioning
  position      NUMERIC NOT NULL CHECK (position > 0),                                          -- its place in the partitioning; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  "column"      TEXT    REFERENCES cortex.columns (id) ON DELETE CASCADE,                       -- the column; NULL for an expression
  expression    TEXT,                                                                           -- the expression, in the engine's SQL; NULL for a column
  transform     TEXT,                                                                           -- the transform, in the engine's words (day, bucket[16]); NULL for the value itself
  UNIQUE (partitioning, position),
  CHECK (("column" IS NULL) <> (expression IS NULL)),
  CHECK (substr(id, 1, length(partitioning) + 3) = partitioning || '.by' AND substr(id, length(partitioning) + 4) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.partition_fields IS 'what a table is partitioned by, in order: a column or an expression, through a transform.';
COMMENT ON COLUMN cortex.partition_fields.id IS '<object>.by<n>, n given once from id_counters and never reused: o_events.by1';
COMMENT ON COLUMN cortex.partition_fields.partitioning IS 'the partitioning';
COMMENT ON COLUMN cortex.partition_fields.position IS 'its place in the partitioning; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.partition_fields."column" IS 'the column; NULL for an expression';
COMMENT ON COLUMN cortex.partition_fields.expression IS 'the expression, in the engine''s SQL; NULL for a column';
COMMENT ON COLUMN cortex.partition_fields.transform IS 'the transform, in the engine''s words (day, bucket[16]); NULL for the value itself';
