-- cortex.locked_versions: a locked version of a design: the log up to one committed turn, its number and the hash of the model it gives; locked once, never changed.
CREATE TABLE cortex.locked_versions (
  id         UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  turn       UUID NOT NULL,                                                                                   -- the last turn it holds
  number     INTEGER NOT NULL CHECK (number >= 1),                                                            -- its number in the design: 1, 2, 3
  hash       TEXT NOT NULL CHECK (hash ~ '^[0-9a-f]{64}$'),                                                   -- the SHA-256 of the model at that turn
  locked_by  TEXT NOT NULL CHECK (length(locked_by) >= 1),                                                    -- who locked it
  locked_at  TIMESTAMPTZ NOT NULL DEFAULT now(),                                                              -- when
  UNIQUE (design, id),
  UNIQUE (design, number),
  FOREIGN KEY (design, turn) REFERENCES cortex.turns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX locked_versions_turn ON cortex.locked_versions (design, turn);
