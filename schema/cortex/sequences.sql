-- cortex.sequences: a sequence object, and how it numbers. Owner: cortex.
CREATE TABLE cortex.sequences (
  id         UUID NOT NULL PRIMARY KEY,                                                                     -- the sequence
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  type       TEXT,                                                                                          -- its type as the engine writes it; NULL for the engine's default
  start      NUMERIC,                                                                                       -- its first number; NULL for the engine's default
  increment  NUMERIC CHECK (increment <> 0),                                                                -- its step; NULL for the engine's default
  min_value  NUMERIC,                                                                                       -- its smallest number; NULL for the engine's default
  max_value  NUMERIC,                                                                                       -- its largest number; NULL for the engine's default
  cache      BIGINT CHECK (cache >= 1),                                                                     -- how many numbers are taken at a time; NULL for the engine's default
  cycle      BOOLEAN NOT NULL DEFAULT false,                                                                -- true when it starts again after its last number
  owned_by   UUID,                                                                                          -- the column that owns it and drops it with itself; NULL for none
  options    JSONB NOT NULL DEFAULT '{}',                                                                   -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, owned_by) REFERENCES cortex.columns (design, id) ON DELETE SET NULL (owned_by) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX sequences_owned_by ON cortex.sequences (design, owned_by);

COMMENT ON TABLE cortex.sequences IS 'a sequence object, and how it numbers.';
COMMENT ON COLUMN cortex.sequences.id IS 'the sequence';
COMMENT ON COLUMN cortex.sequences.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.sequences.type IS 'its type as the engine writes it; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.start IS 'its first number; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.increment IS 'its step; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.min_value IS 'its smallest number; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.max_value IS 'its largest number; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.cache IS 'how many numbers are taken at a time; NULL for the engine''s default';
COMMENT ON COLUMN cortex.sequences.cycle IS 'true when it starts again after its last number';
COMMENT ON COLUMN cortex.sequences.owned_by IS 'the column that owns it and drops it with itself; NULL for none';
COMMENT ON COLUMN cortex.sequences.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}';
