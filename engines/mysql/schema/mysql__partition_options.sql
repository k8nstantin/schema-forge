-- mysql__partition_options: the options of a partition, or of a subpartition.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__partition_options (
  id               TEXT     NOT NULL PRIMARY KEY,                           -- a partition's id, or a subpartition's id
  engine           TEXT,    -- its storage engine; NULL when not written
  comment          TEXT,    -- what it holds; NULL when not written
  data_directory   TEXT,    -- where its data file is; NULL when not written
  index_directory  TEXT,    -- where its index file is; NULL when not written
  max_rows         INTEGER  CHECK (max_rows >= 0),                          -- the most rows it is sized for; NULL when not written
  min_rows         INTEGER  CHECK (min_rows >= 0),                          -- the fewest rows it is sized for; NULL when not written
  tablespace       TEXT     -- the tablespace it is stored in; NULL when not written
) STRICT;
