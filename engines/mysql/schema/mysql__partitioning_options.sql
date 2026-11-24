-- mysql__partitioning_options: what MySQL says of a table's partitioning beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__partitioning_options (
  id         TEXT     NOT NULL PRIMARY KEY REFERENCES partitionings (id) ON DELETE CASCADE,  -- the partitioning
  linear     INTEGER  NOT NULL DEFAULT 0 CHECK (linear IN (0, 1)),          -- 1 for LINEAR HASH or LINEAR KEY
  algorithm  INTEGER  CHECK (algorithm IN (1, 2)),                          -- the KEY hashing algorithm (ALGORITHM=1|2); NULL when not written
  count      INTEGER  CHECK (count >= 1),                                   -- how many partitions, when they are not named (PARTITIONS n); NULL when not written
  "columns"  INTEGER  NOT NULL DEFAULT 0 CHECK ("columns" IN (0, 1))        -- 1 for RANGE COLUMNS or LIST COLUMNS
) STRICT;
