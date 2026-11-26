-- cortex.savepoints: a turn someone named, to open or restore later. Owner: cortex.
CREATE TABLE cortex.savepoints (
  id       UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design   UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it marks a turn of
  name     TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- as people call it
  turn     UUID NOT NULL,                                                                                 -- the turn it marks
  made_by  TEXT NOT NULL CHECK (length(made_by) >= 1),                                                    -- who named it
  made_at  TIMESTAMPTZ NOT NULL,                                                                          -- when
  UNIQUE (design, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, turn) REFERENCES cortex.turns (design, id)
);

CREATE INDEX savepoints_turn ON cortex.savepoints (design, turn);

COMMENT ON TABLE cortex.savepoints IS 'a turn someone named, to open or restore later.';
COMMENT ON COLUMN cortex.savepoints.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.savepoints.design IS 'the design it marks a turn of';
COMMENT ON COLUMN cortex.savepoints.name IS 'as people call it';
COMMENT ON COLUMN cortex.savepoints.turn IS 'the turn it marks';
COMMENT ON COLUMN cortex.savepoints.made_by IS 'who named it';
COMMENT ON COLUMN cortex.savepoints.made_at IS 'when';
