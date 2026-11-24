-- mysql__key_options: what MySQL says of a primary or unique key beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__key_options (
  id                TEXT     NOT NULL PRIMARY KEY REFERENCES keys (id) ON DELETE CASCADE,  -- the key
  method            TEXT     CHECK (method IN ('BTREE', 'HASH')),          -- how it is built (USING); NULL when not written
  comment           TEXT,    -- what it is for; NULL when not written
  key_block_size    INTEGER  CHECK (key_block_size >= 0),                  -- its block size, in KB; NULL when not written
  invisible         INTEGER  CHECK (invisible IN (0, 1)),                  -- 1 when the optimizer ignores it; NULL when not written
  engine_attribute  TEXT     -- what its storage engine is told about it; NULL when not written
) STRICT;
