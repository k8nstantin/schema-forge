-- engine_mysql.partition_options: the options of a partition; a subpartition's are in engine_mysql.subpartition_options.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.partition_options (
  id               TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.partitions (id) ON DELETE CASCADE,  -- the partition
  engine           TEXT,                                                                              -- its storage engine; NULL when not written
  comment          TEXT,                                                                              -- what it holds; NULL when not written
  data_directory   TEXT,                                                                              -- where its data file is; NULL when not written
  index_directory  TEXT,                                                                              -- where its index file is; NULL when not written
  max_rows         INTEGER CHECK (max_rows >= 0),                                                     -- the most rows it is sized for; NULL when not written
  min_rows         INTEGER CHECK (min_rows >= 0),                                                     -- the fewest rows it is sized for; NULL when not written
  tablespace       TEXT                                                                               -- the tablespace it is stored in; NULL when not written
);

COMMENT ON TABLE engine_mysql.partition_options IS 'the options of a partition; a subpartition''s are in engine_mysql.subpartition_options. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.partition_options.id IS 'the partition';
COMMENT ON COLUMN engine_mysql.partition_options.engine IS 'its storage engine; NULL when not written';
COMMENT ON COLUMN engine_mysql.partition_options.comment IS 'what it holds; NULL when not written';
COMMENT ON COLUMN engine_mysql.partition_options.data_directory IS 'where its data file is; NULL when not written';
COMMENT ON COLUMN engine_mysql.partition_options.index_directory IS 'where its index file is; NULL when not written';
COMMENT ON COLUMN engine_mysql.partition_options.max_rows IS 'the most rows it is sized for; NULL when not written';
COMMENT ON COLUMN engine_mysql.partition_options.min_rows IS 'the fewest rows it is sized for; NULL when not written';
COMMENT ON COLUMN engine_mysql.partition_options.tablespace IS 'the tablespace it is stored in; NULL when not written';
