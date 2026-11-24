-- column_identities: a column the database numbers itself, and how. Owner: cortex.
CREATE TABLE column_identities (
  id         TEXT    NOT NULL PRIMARY KEY REFERENCES columns (id) ON DELETE CASCADE,  -- the column numbered
  always     INTEGER NOT NULL CHECK (always IN (0, 1)),                       -- 1 when a value can never be given (ALWAYS); 0 only when none is (BY DEFAULT)
  start      INTEGER,                                                         -- the first number; NULL for the engine's default
  increment  INTEGER CHECK (increment <> 0),                                  -- the step; NULL for the engine's default
  min_value  INTEGER,                                                         -- the smallest number; NULL for the engine's default
  max_value  INTEGER,                                                         -- the largest number; NULL for the engine's default
  cache      INTEGER CHECK (cache >= 1),                                      -- how many numbers are taken at a time; NULL for the engine's default
  cycle      INTEGER NOT NULL DEFAULT 0 CHECK (cycle IN (0, 1))               -- 1 when it starts again after its last number
) STRICT;
