-- kept: what the schema holds that the model does not describe (an account, a grant, a statement not understood), kept exactly as written and written back in its place. Owner: cortex.
CREATE TABLE kept (
  id        TEXT    NOT NULL PRIMARY KEY,                                      -- kept<position>: kept1
  position  INTEGER NOT NULL UNIQUE CHECK (position >= 1),                     -- its place in the order it was read
  kind      TEXT    NOT NULL CHECK (length(kind) >= 1),                        -- what it is, in the engine's words (account, grant, other)
  text      TEXT    NOT NULL,                                                  -- the statement, exactly as written
  after     TEXT    REFERENCES objects (id) ON DELETE SET NULL,                -- the object it is written after; NULL for the start
  CHECK (id = 'kept' || position)
) STRICT;
