-- partitions: the partitions defined in a table itself, in order, with their bounds. Owner: cortex.
CREATE TABLE partitions (
  id            TEXT    NOT NULL PRIMARY KEY,                                  -- <object>.partition<position>: o_events.partition1
  partitioning  TEXT    NOT NULL REFERENCES partitionings (id) ON DELETE CASCADE,  -- the partitioning
  position      INTEGER NOT NULL CHECK (position >= 1),                        -- its place among the partitions
  name          TEXT    NOT NULL CHECK (length(name) >= 1),                    -- its name
  bounds        TEXT    NOT NULL,                                              -- its bounds in the engine's SQL (VALUES LESS THAN (2025)); empty when its strategy gives none
  UNIQUE (partitioning, position),
  UNIQUE (partitioning, name),
  CHECK (id = partitioning || '.partition' || position)
) STRICT;
