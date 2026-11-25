-- cortex.partitionings: how a table is split into partitions. Owner: cortex.
CREATE TABLE cortex.partitionings (
  id          BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the table split
  strategy    TEXT NOT NULL,                                                                                               -- the way rows are split, in the engine's words (RANGE, LIST, HASH, KEY)
  expression  TEXT NOT NULL                                                                                                -- what it is split by, as the engine writes it (year(`d`), (taken))
);

COMMENT ON TABLE cortex.partitionings IS 'how a table is split into partitions.';
COMMENT ON COLUMN cortex.partitionings.id IS 'the table split';
COMMENT ON COLUMN cortex.partitionings.strategy IS 'the way rows are split, in the engine''s words (RANGE, LIST, HASH, KEY)';
COMMENT ON COLUMN cortex.partitionings.expression IS 'what it is split by, as the engine writes it (year(`d`), (taken))';
