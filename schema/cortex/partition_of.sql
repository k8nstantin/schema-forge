-- partition_of: a table that is a partition of another, and the rows it holds. Owner: cortex.
CREATE TABLE partition_of (
  id      TEXT    NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the partition
  parent  TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,      -- the table it is a partition of
  bounds  TEXT    NOT NULL CHECK (length(bounds) >= 1),                    -- the rows it holds, in the engine's SQL
  CHECK (id <> parent)
) STRICT;
