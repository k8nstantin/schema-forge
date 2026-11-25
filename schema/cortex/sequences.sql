-- cortex.sequences: a sequence object, and how it numbers. Owner: cortex.
CREATE TABLE cortex.sequences (
  id         BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the sequence
  type       TEXT,                                                                                                        -- its type as the engine writes it; NULL for the engine's default
  start      NUMERIC,                                                                                                     -- its first number; NULL for the engine's default
  increment  NUMERIC CHECK (increment <> 0),                                                                              -- its step; NULL for the engine's default
  min_value  NUMERIC,                                                                                                     -- its smallest number; NULL for the engine's default
  max_value  NUMERIC,                                                                                                     -- its largest number; NULL for the engine's default
  cache      BIGINT CHECK (cache >= 1),                                                                                   -- how many numbers are taken at a time; NULL for the engine's default
  cycle      BOOLEAN NOT NULL DEFAULT false,                                                                              -- true when it starts again after its last number
  owned_by   BIGINT REFERENCES cortex.columns (id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED                       -- the column that owns it and drops it with itself; NULL for none
);

COMMENT ON TABLE cortex.sequences IS 'a sequence object, and how it numbers.';
COMMENT ON COLUMN cortex.sequences.id IS 'the sequence';
COMMENT ON COLUMN cortex.sequences.type IS 'its type as the engine writes it; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.start IS 'its first number; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.increment IS 'its step; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.min_value IS 'its smallest number; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.max_value IS 'its largest number; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.cache IS 'how many numbers are taken at a time; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.cycle IS 'true when it starts again after its last number';
COMMENT ON COLUMN cortex.sequences.owned_by IS 'the column that owns it and drops it with itself; NULL for none';
