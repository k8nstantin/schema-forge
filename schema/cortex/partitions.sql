-- cortex.partitions: the partitions defined in a table itself, in order, with their bounds. Owner: cortex.
CREATE TABLE cortex.partitions (
  id            TEXT    NOT NULL PRIMARY KEY,                                                   -- <object>.partition<n>, n given once from id_counters and never reused: o_events.partition1
  partitioning  TEXT    NOT NULL REFERENCES cortex.table_partitionings (id) ON DELETE CASCADE,  -- the partitioning
  position      NUMERIC NOT NULL CHECK (position > 0),                                          -- its place among the partitions; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name          TEXT    NOT NULL CHECK (length(name) >= 1),                                     -- its name
  bounds        TEXT    NOT NULL,                                                               -- its bounds in the engine's SQL (VALUES LESS THAN (2025)); empty when its strategy gives none
  UNIQUE (partitioning, position),
  UNIQUE (partitioning, name),
  CHECK (substr(id, 1, length(partitioning) + 10) = partitioning || '.partition' AND substr(id, length(partitioning) + 11) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.partitions IS 'the partitions defined in a table itself, in order, with their bounds.';
COMMENT ON COLUMN cortex.partitions.id IS '<object>.partition<n>, n given once from id_counters and never reused: o_events.partition1';
COMMENT ON COLUMN cortex.partitions.partitioning IS 'the partitioning';
COMMENT ON COLUMN cortex.partitions.position IS 'its place among the partitions; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.partitions.name IS 'its name';
COMMENT ON COLUMN cortex.partitions.bounds IS 'its bounds in the engine''s SQL (VALUES LESS THAN (2025)); empty when its strategy gives none';
