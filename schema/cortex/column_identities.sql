-- cortex.column_identities: a column the database numbers itself, and how. Owner: cortex.
CREATE TABLE cortex.column_identities (
  id         TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.columns (id) ON DELETE CASCADE,  -- the column numbered
  always     BOOLEAN NOT NULL,                                                               -- true when a value can never be given (ALWAYS); 0 only when none is (BY DEFAULT)
  start      BIGINT,                                                                         -- the first number; NULL for the engine's default
  increment  BIGINT  CHECK (increment <> 0),                                                 -- the step; NULL for the engine's default
  min_value  BIGINT,                                                                         -- the smallest number; NULL for the engine's default
  max_value  BIGINT,                                                                         -- the largest number; NULL for the engine's default
  cache      BIGINT  CHECK (cache >= 1),                                                     -- how many numbers are taken at a time; NULL for the engine's default
  cycle      BOOLEAN NOT NULL DEFAULT false                                                  -- true when it starts again after its last number
);

COMMENT ON TABLE cortex.column_identities IS 'a column the database numbers itself, and how.';
COMMENT ON COLUMN cortex.column_identities.id IS 'the column numbered';
COMMENT ON COLUMN cortex.column_identities.always IS 'true when a value can never be given (ALWAYS); 0 only when none is (BY DEFAULT)';
COMMENT ON COLUMN cortex.column_identities.start IS 'the first number; NULL for the engine''s default';
COMMENT ON COLUMN cortex.column_identities.increment IS 'the step; NULL for the engine''s default';
COMMENT ON COLUMN cortex.column_identities.min_value IS 'the smallest number; NULL for the engine''s default';
COMMENT ON COLUMN cortex.column_identities.max_value IS 'the largest number; NULL for the engine''s default';
COMMENT ON COLUMN cortex.column_identities.cache IS 'how many numbers are taken at a time; NULL for the engine''s default';
COMMENT ON COLUMN cortex.column_identities.cycle IS 'true when it starts again after its last number';
