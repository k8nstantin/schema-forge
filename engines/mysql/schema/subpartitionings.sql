-- engine_mysql.subpartitionings: how each partition of a table is split again (SUBPARTITION BY). Owner: mysql.
CREATE TABLE engine_mysql.subpartitionings (
  id          BIGINT NOT NULL PRIMARY KEY,                                                                   -- the partitioning
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  strategy    TEXT NOT NULL,                                                                                 -- how a partition is split again (HASH, KEY, LINEAR HASH)
  expression  TEXT NOT NULL,                                                                                 -- what it is split by, as the server writes it
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.partitionings (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_mysql.subpartitionings IS 'how each partition of a table is split again (SUBPARTITION BY).';
COMMENT ON COLUMN engine_mysql.subpartitionings.id IS 'the partitioning';
COMMENT ON COLUMN engine_mysql.subpartitionings.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_mysql.subpartitionings.strategy IS 'how a partition is split again (HASH, KEY, LINEAR HASH)';
COMMENT ON COLUMN engine_mysql.subpartitionings.expression IS 'what it is split by, as the server writes it';
