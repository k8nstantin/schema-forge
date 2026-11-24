-- mysql__subpartitionings: how each partition of a table is split again (SUBPARTITION BY ...).
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__subpartitionings (
  id        TEXT     NOT NULL PRIMARY KEY REFERENCES partitionings (id) ON DELETE CASCADE,  -- the partitioning
  strategy  TEXT     NOT NULL CHECK (strategy IN ('hash', 'key')),          -- how a partition is split again
  by_text   TEXT     NOT NULL CHECK (length(by_text) >= 1),                 -- what it is split by, exactly as written (the expression of HASH, the columns of KEY)
  linear    INTEGER  NOT NULL DEFAULT 0 CHECK (linear IN (0, 1)),           -- 1 for LINEAR
  count     INTEGER  CHECK (count >= 1)                                     -- how many subpartitions, when they are not named (SUBPARTITIONS n); NULL when not written
) STRICT;
