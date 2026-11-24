-- cortex.operations: the log: every change, appended, never edited or deleted (decision 5). Owner: cortex.
-- The current model (every other cortex and engine table) is written in the same transaction as its operation;
-- replaying the log from an empty database rebuilds it exactly.
CREATE TABLE cortex.operations (
  id       UUID        NOT NULL PRIMARY KEY CHECK (uuid_extract_version(id) = 7),     -- UUIDv7, issued in increasing order by the store, the database's one writer: its order is the commit order (decision 7)
  turn     UUID        NOT NULL REFERENCES cortex.turns (id),                         -- the turn it belongs to (decision 8)
  kind     TEXT        NOT NULL CHECK (kind ~ '^[a-z0-9_]+$' AND length(kind) >= 1),  -- what it is: one of the operation kinds, which the root decision operation-kinds settles before the operations task (import is the one kind the store task writes)
  summary  TEXT        NOT NULL CHECK (length(summary) >= 1),                         -- what it did, in one line (added table orders)
  at       TIMESTAMPTZ NOT NULL                                                       -- when it was committed
);

COMMENT ON TABLE cortex.operations IS 'the log: every change, appended, never edited or deleted (decision 5). The current model (every other cortex and engine table) is written in the same transaction as its operation; replaying the log from an empty database rebuilds it exactly.';
COMMENT ON COLUMN cortex.operations.id IS 'UUIDv7, issued in increasing order by the store, the database''s one writer: its order is the commit order (decision 7)';
COMMENT ON COLUMN cortex.operations.turn IS 'the turn it belongs to (decision 8)';
COMMENT ON COLUMN cortex.operations.kind IS 'what it is: one of the operation kinds, which the root decision operation-kinds settles before the operations task (import is the one kind the store task writes)';
COMMENT ON COLUMN cortex.operations.summary IS 'what it did, in one line (added table orders)';
COMMENT ON COLUMN cortex.operations.at IS 'when it was committed';
