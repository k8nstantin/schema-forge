-- operations: the log: every change, appended, never edited or deleted (decision 5). Owner: cortex.
-- The current model (every other cortex and engine table) is written in the same transaction as its operation;
-- replaying the log from an empty file rebuilds it exactly.
CREATE TABLE operations (
  id       TEXT  NOT NULL PRIMARY KEY CHECK (length(id) = 36 AND substr(id, 15, 1) = '7'),  -- UUIDv7, issued in increasing order by the file's one writer: its order is the commit order (decision 7)
  turn     TEXT  NOT NULL REFERENCES turns (id),                             -- the turn it belongs to (decision 8)
  kind     TEXT  NOT NULL CHECK (kind NOT GLOB '*[^a-z0-9_]*' AND length(kind) >= 1),  -- what it is: one of the operation kinds, which the root decision operation-kinds settles before the operations task (import is the one kind the store task writes)
  summary  TEXT  NOT NULL CHECK (length(summary) >= 1),                      -- what it did, in one line (added table orders)
  at       TEXT  NOT NULL                                                    -- when it was committed, UTC, RFC 3339
) STRICT;
