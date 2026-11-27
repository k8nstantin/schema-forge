-- engine_mysql.partitions: the partitions of a partitioned table in order, and each one's subpartitions under it, with the options each writes.
CREATE TABLE engine_mysql.partitions (
  id               UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row
  design           UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  partitioning     UUID NOT NULL,                                                                                   -- the table's partitioning
  parent           UUID,                                                                                            -- for a subpartition, its partition; NULL for a partition
  position         INTEGER NOT NULL CHECK (position >= 1),                                                          -- its place among its siblings, as the server orders them
  name             TEXT NOT NULL CHECK (length(name) >= 1),                                                         -- as the server names it (p0)
  "values"         TEXT,                                                                                            -- VALUES LESS THAN (...) or VALUES IN (...), as written; NULL for HASH and KEY
  engine           TEXT,                                                                                            -- ENGINE, where written
  comment          TEXT,                                                                                            -- COMMENT, where written
  data_directory   TEXT,                                                                                            -- DATA DIRECTORY, where written
  index_directory  TEXT,                                                                                            -- INDEX DIRECTORY, where written
  max_rows         BIGINT,                                                                                          -- MAX_ROWS, where written
  min_rows         BIGINT,                                                                                          -- MIN_ROWS, where written
  tablespace       TEXT,                                                                                            -- TABLESPACE, where written
  flavor_options   JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(flavor_options) = 'object'),                     -- what only its flavor says of it, by the keys its flavor declares
  UNIQUE (design, id),
  UNIQUE NULLS NOT DISTINCT (partitioning, parent, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (partitioning, name) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, partitioning) REFERENCES engine_mysql.partitionings (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, parent) REFERENCES engine_mysql.partitions (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX partitions_partitioning ON engine_mysql.partitions (design, partitioning);
CREATE INDEX partitions_parent ON engine_mysql.partitions (design, parent);
