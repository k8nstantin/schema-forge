-- cortex.operations: what a turn did, one operation at a time, each named as the agent and the canvas name it (add_table orders); its row changes are what it changed.
CREATE TABLE cortex.operations (
  id        UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  turn      UUID NOT NULL,                                                                                   -- the turn it belongs to
  position  INTEGER NOT NULL CHECK (position >= 1),                                                          -- its place in the turn: 1, 2, 3
  kind      TEXT NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_]*$'),                                                -- what it is, as the agent and the canvas name it (add_table)
  summary   TEXT NOT NULL CHECK (length(summary) >= 1),                                                      -- what it did, for people (added table orders)
  UNIQUE (design, id),
  UNIQUE (turn, position),
  FOREIGN KEY (design, turn) REFERENCES cortex.turns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX operations_turn ON cortex.operations (design, turn);
