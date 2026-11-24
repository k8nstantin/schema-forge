-- partition_fields: what a table is partitioned by, in order: a column or an expression, through a transform. Owner: cortex.
CREATE TABLE partition_fields (
  id          TEXT    NOT NULL PRIMARY KEY,                                    -- <object>.by<position>: o_events.by1
  partitioning TEXT   NOT NULL REFERENCES partitionings (id) ON DELETE CASCADE, -- the partitioning
  position    INTEGER NOT NULL CHECK (position >= 1),                          -- its place in the partitioning
  "column"    TEXT    REFERENCES columns (id) ON DELETE CASCADE,               -- the column; NULL for an expression
  expression  TEXT,                                                            -- the expression, in the engine's SQL; NULL for a column
  transform   TEXT,                                                            -- the transform, in the engine's words (day, bucket[16]); NULL for the value itself
  UNIQUE (partitioning, position),
  CHECK (("column" IS NULL) <> (expression IS NULL)),
  CHECK (id = partitioning || '.by' || position)
) STRICT;
