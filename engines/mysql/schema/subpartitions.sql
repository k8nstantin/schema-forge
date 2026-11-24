-- engine_mysql.subpartitions: the named subpartitions of a partition, in order; their options are in engine_mysql.subpartition_options.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.subpartitions (
  id         TEXT    NOT NULL PRIMARY KEY,                                          -- <partition>.sub<n>, n given once from id_counters and never reused
  partition  TEXT    NOT NULL REFERENCES cortex.partitions (id) ON DELETE CASCADE,  -- the partition split
  position   NUMERIC NOT NULL CHECK (position > 0),                                 -- its place among the partition's subpartitions; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name       TEXT    NOT NULL CHECK (length(name) >= 1),                            -- its name
  UNIQUE (partition, position),
  UNIQUE (partition, name),
  CHECK (substr(id, 1, length(partition) + 4) = partition || '.sub' AND substr(id, length(partition) + 5) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_mysql.subpartitions IS 'the named subpartitions of a partition, in order; their options are in engine_mysql.subpartition_options. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.subpartitions.id IS '<partition>.sub<n>, n given once from id_counters and never reused';
COMMENT ON COLUMN engine_mysql.subpartitions.partition IS 'the partition split';
COMMENT ON COLUMN engine_mysql.subpartitions.position IS 'its place among the partition''s subpartitions; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_mysql.subpartitions.name IS 'its name';
