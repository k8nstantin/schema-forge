-- cortex.operations: what a turn did, one operation at a time, each of a kind the agent and the canvas name (added table orders). Owner: cortex.
CREATE TABLE cortex.operations (
  id       UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, issued by the database: its order is the order they were committed
  design   UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  turn     UUID NOT NULL,                                                                                 -- the turn it belongs to
  kind     TEXT NOT NULL CHECK (kind ~ '^[a-z0-9_]+$'),                                                   -- what it is: one of the operation kinds
  summary  TEXT NOT NULL CHECK (length(summary) >= 1),                                                    -- what it did, in one line
  at       TIMESTAMPTZ NOT NULL,                                                                          -- when it was committed
  UNIQUE (design, id),
  FOREIGN KEY (design, turn) REFERENCES cortex.turns (design, id) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX operations_turn ON cortex.operations (design, turn);

COMMENT ON TABLE cortex.operations IS 'what a turn did, one operation at a time, each of a kind the agent and the canvas name (added table orders).';
COMMENT ON COLUMN cortex.operations.id IS 'UUIDv7, issued by the database: its order is the order they were committed';
COMMENT ON COLUMN cortex.operations.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.operations.turn IS 'the turn it belongs to';
COMMENT ON COLUMN cortex.operations.kind IS 'what it is: one of the operation kinds';
COMMENT ON COLUMN cortex.operations.summary IS 'what it did, in one line';
COMMENT ON COLUMN cortex.operations.at IS 'when it was committed';
