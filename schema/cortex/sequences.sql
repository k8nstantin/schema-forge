-- sequences: a sequence object, and how it numbers. Owner: cortex.
CREATE TABLE sequences (
  id         TEXT    NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the sequence
  type       TEXT,                                                             -- its type as the engine writes it; NULL for the engine's default
  start      INTEGER,                                                          -- NULL for the engine's default
  increment  INTEGER CHECK (increment <> 0),                                   -- NULL for the engine's default
  min_value  INTEGER,                                                          -- NULL for the engine's default
  max_value  INTEGER,                                                          -- NULL for the engine's default
  cache      INTEGER CHECK (cache >= 1),                                       -- NULL for the engine's default
  cycle      INTEGER NOT NULL DEFAULT 0 CHECK (cycle IN (0, 1)),               -- 1 when it starts again after its last number
  owned_by   TEXT    REFERENCES columns (id) ON DELETE SET NULL                -- the column that owns it and drops it with itself; NULL for none
) STRICT;
