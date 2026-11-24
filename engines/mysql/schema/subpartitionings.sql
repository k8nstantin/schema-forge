-- engine_mysql.subpartitionings: how each partition of a table is split again (SUBPARTITION BY ...).
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.subpartitionings (
  id        TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.table_partitionings (id) ON DELETE CASCADE,  -- the partitioning
  strategy  TEXT    NOT NULL CHECK (strategy IN ('hash', 'key')),               -- how a partition is split again
  by_text   TEXT    NOT NULL CHECK (length(by_text) >= 1),                      -- what it is split by, exactly as written (the expression of HASH, the columns of KEY)
  linear    BOOLEAN NOT NULL DEFAULT false,                                     -- true for LINEAR
  count     INTEGER CHECK (count >= 1)                                          -- how many subpartitions, when they are not named (SUBPARTITIONS n); NULL when not written
);

COMMENT ON TABLE engine_mysql.subpartitionings IS 'how each partition of a table is split again (SUBPARTITION BY ...). Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.subpartitionings.id IS 'the partitioning';
COMMENT ON COLUMN engine_mysql.subpartitionings.strategy IS 'how a partition is split again';
COMMENT ON COLUMN engine_mysql.subpartitionings.by_text IS 'what it is split by, exactly as written (the expression of HASH, the columns of KEY)';
COMMENT ON COLUMN engine_mysql.subpartitionings.linear IS 'true for LINEAR';
COMMENT ON COLUMN engine_mysql.subpartitionings.count IS 'how many subpartitions, when they are not named (SUBPARTITIONS n); NULL when not written';
