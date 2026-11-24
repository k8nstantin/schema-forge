-- mysql__subpartitions: the named subpartitions of a partition, in order; their options are in mysql__partition_options.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__subpartitions (
  id         TEXT     NOT NULL PRIMARY KEY,                                 -- <partition>.sub<position>
  partition  TEXT     NOT NULL REFERENCES partitions (id) ON DELETE CASCADE,  -- the partition split
  position   INTEGER  NOT NULL CHECK (position >= 1),                       -- its place among the partition's subpartitions
  name       TEXT     NOT NULL CHECK (length(name) >= 1),                   -- its name
  UNIQUE (partition, position),
  UNIQUE (partition, name),
  CHECK (id = partition || '.sub' || position)
) STRICT;
