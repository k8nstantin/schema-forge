-- engine_mysql.partitionings: how a table is partitioned, and its subpartitions: one row per partitioned table, with the same id as the table.
CREATE TABLE engine_mysql.partitionings (
  id                 UUID NOT NULL PRIMARY KEY,                                                                                  -- its table's cortex object
  design             UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,               -- the design
  method             TEXT NOT NULL CHECK (method IN ('RANGE', 'RANGE COLUMNS', 'LIST', 'LIST COLUMNS', 'HASH', 'LINEAR HASH', 'KEY', 'LINEAR KEY')),  -- PARTITION BY
  expression         TEXT,                                                                                                       -- the expression or column list it partitions by, as the server writes it
  key_algorithm      INTEGER CHECK (key_algorithm IN (1, 2)),                                                                    -- ALGORITHM of a KEY partitioning, where written
  partition_count    INTEGER CHECK (partition_count >= 1),                                                                       -- PARTITIONS n, where the server writes the count and not each partition
  sub_method         TEXT CHECK (sub_method IN ('HASH', 'LINEAR HASH', 'KEY', 'LINEAR KEY')),                                    -- SUBPARTITION BY, where written
  sub_expression     TEXT,                                                                                                       -- what it subpartitions by
  sub_key_algorithm  INTEGER CHECK (sub_key_algorithm IN (1, 2)),                                                                -- ALGORITHM of a KEY subpartitioning, where written
  subpartition_count INTEGER CHECK (subpartition_count >= 1),                                                                    -- SUBPARTITIONS n, where written
  UNIQUE (design, id),
  CHECK ((sub_method IS NULL) = (sub_expression IS NULL) OR sub_method LIKE '%KEY'),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
