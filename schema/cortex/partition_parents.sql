-- cortex.partition_parents: a table that is a partition of another, and the rows it holds. Owner: cortex.
CREATE TABLE cortex.partition_parents (
  id      TEXT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the partition
  parent  TEXT NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,              -- the table it is a partition of
  bounds  TEXT NOT NULL CHECK (length(bounds) >= 1),                                   -- the rows it holds, in the engine's SQL
  CHECK (id <> parent)
);

COMMENT ON TABLE cortex.partition_parents IS 'a table that is a partition of another, and the rows it holds.';
COMMENT ON COLUMN cortex.partition_parents.id IS 'the partition';
COMMENT ON COLUMN cortex.partition_parents.parent IS 'the table it is a partition of';
COMMENT ON COLUMN cortex.partition_parents.bounds IS 'the rows it holds, in the engine''s SQL';
