-- kept: what the schema holds that the model does not describe (an account, a grant, a statement not understood), kept exactly as written and written back in its place. Owner: cortex.
CREATE TABLE kept (
  id        TEXT    NOT NULL PRIMARY KEY,                                      -- kept<position>: kept1
  position  INTEGER NOT NULL UNIQUE CHECK (position >= 1),                     -- its place in the order it was read
  kind      TEXT    NOT NULL CHECK (length(kind) >= 1),                        -- what it is, in the engine's words (account, grant, other)
  text      TEXT    NOT NULL,                                                  -- the statement, exactly as written
  after_namespace  TEXT  REFERENCES namespaces (id) ON DELETE SET NULL,        -- the namespace it is written after (a statement kept after a switch of namespace); NULL when it follows an object or the start
  after_object     TEXT  REFERENCES objects (id) ON DELETE SET NULL,           -- the object it is written after; NULL when it follows a namespace or the start
  CHECK (after_namespace IS NULL OR after_object IS NULL),
  CHECK (id = 'kept' || position)
) STRICT;
