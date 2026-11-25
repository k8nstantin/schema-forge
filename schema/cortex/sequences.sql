-- cortex.sequences: a sequence object, and how it numbers. Owner: cortex.
CREATE TABLE cortex.sequences (
  id         TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the sequence
  type       TEXT,                                                                           -- its type as the engine writes it; NULL for the engine's default
  start      BIGINT,                                                                         -- NULL for the engine's default
  increment  BIGINT  CHECK (increment <> 0),                                                 -- NULL for the engine's default
  min_value  BIGINT,                                                                         -- NULL for the engine's default
  max_value  BIGINT,                                                                         -- NULL for the engine's default
  cache      BIGINT  CHECK (cache >= 1),                                                     -- NULL for the engine's default
  cycle      BOOLEAN NOT NULL DEFAULT false,                                                 -- true when it starts again after its last number
  owned_by   TEXT    REFERENCES cortex.columns (id) ON DELETE SET NULL                       -- the column that owns it and drops it with itself; NULL for none
);

COMMENT ON TABLE cortex.sequences IS 'a sequence object, and how it numbers.';
COMMENT ON COLUMN cortex.sequences.id IS 'the sequence';
COMMENT ON COLUMN cortex.sequences.type IS 'its type as the engine writes it; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.start IS 'NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.increment IS 'NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.min_value IS 'NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.max_value IS 'NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.cache IS 'NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.cycle IS 'true when it starts again after its last number';
COMMENT ON COLUMN cortex.sequences.owned_by IS 'the column that owns it and drops it with itself; NULL for none';
