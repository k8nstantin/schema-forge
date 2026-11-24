-- cortex.table_partitionings: how a table is split into partitions. Owner: cortex.
CREATE TABLE cortex.table_partitionings (
  id        TEXT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the table split
  strategy  TEXT                                                                         -- the way rows are split, in the engine's words (range, list, hash, key); NULL when each field says its own transform
);

COMMENT ON TABLE cortex.table_partitionings IS 'how a table is split into partitions.';
COMMENT ON COLUMN cortex.table_partitionings.id IS 'the table split';
COMMENT ON COLUMN cortex.table_partitionings.strategy IS 'the way rows are split, in the engine''s words (range, list, hash, key); NULL when each field says its own transform';
