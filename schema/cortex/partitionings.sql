-- partitionings: how a table is split into partitions. Owner: cortex.
CREATE TABLE partitionings (
  id        TEXT    NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the table split
  strategy  TEXT                                                               -- the way rows are split, in the engine's words (range, list, hash, key); NULL when each field says its own transform
) STRICT;
