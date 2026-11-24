-- engine_mysql.table_partitioning_options: what MySQL says of a table's partitioning beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.table_partitioning_options (
  id         TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.table_partitionings (id) ON DELETE CASCADE,  -- the partitioning
  linear     BOOLEAN NOT NULL DEFAULT false,                                    -- true for LINEAR HASH or LINEAR KEY
  algorithm  INTEGER CHECK (algorithm IN (1, 2)),                               -- the KEY hashing algorithm (ALGORITHM=1|2); NULL when not written
  count      INTEGER CHECK (count >= 1),                                        -- how many partitions, when they are not named (PARTITIONS n); NULL when not written
  "columns"  BOOLEAN NOT NULL DEFAULT false                                     -- true for RANGE COLUMNS or LIST COLUMNS
);

COMMENT ON TABLE engine_mysql.table_partitioning_options IS 'what MySQL says of a table''s partitioning beyond the cortex. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.table_partitioning_options.id IS 'the partitioning';
COMMENT ON COLUMN engine_mysql.table_partitioning_options.linear IS 'true for LINEAR HASH or LINEAR KEY';
COMMENT ON COLUMN engine_mysql.table_partitioning_options.algorithm IS 'the KEY hashing algorithm (ALGORITHM=1|2); NULL when not written';
COMMENT ON COLUMN engine_mysql.table_partitioning_options.count IS 'how many partitions, when they are not named (PARTITIONS n); NULL when not written';
COMMENT ON COLUMN engine_mysql.table_partitioning_options."columns" IS 'true for RANGE COLUMNS or LIST COLUMNS';
