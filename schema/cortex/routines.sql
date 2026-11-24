-- routines: a procedure, a function or a library: what it returns, how it runs, and its body exactly as written. Owner: cortex.
CREATE TABLE routines (
  id             TEXT    NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the routine
  returns        TEXT,                                                         -- what a function returns, as the engine writes the type; NULL for a procedure
  language       TEXT,                                                         -- its language in the engine's words (sql, javascript); NULL for the engine's own
  deterministic  INTEGER CHECK (deterministic IN (0, 1)),                      -- 1 when the same arguments always give the same result; NULL when it says nothing
  security       TEXT,                                                         -- whose rights it runs with, in the engine's words (definer, invoker); NULL for the engine's default
  body           TEXT    NOT NULL                                              -- its body, exactly as written
) STRICT;
