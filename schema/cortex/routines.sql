-- cortex.routines: a procedure, a function or a library: what it returns, how it runs, and its body exactly as written. Owner: cortex.
CREATE TABLE cortex.routines (
  id             TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the routine
  returns        TEXT,                                                                           -- what a function returns, as the engine writes the type; NULL for a procedure
  language       TEXT,                                                                           -- its language in the engine's words (sql, javascript); NULL for the engine's own
  deterministic  BOOLEAN,                                                                        -- true when the same arguments always give the same result; NULL when it says nothing
  security       TEXT,                                                                           -- whose rights it runs with, in the engine's words (definer, invoker); NULL for the engine's default
  body           TEXT    NOT NULL                                                                -- its body, exactly as written
);

COMMENT ON TABLE cortex.routines IS 'a procedure, a function or a library: what it returns, how it runs, and its body exactly as written.';
COMMENT ON COLUMN cortex.routines.id IS 'the routine';
COMMENT ON COLUMN cortex.routines.returns IS 'what a function returns, as the engine writes the type; NULL for a procedure';
COMMENT ON COLUMN cortex.routines.language IS 'its language in the engine''s words (sql, javascript); NULL for the engine''s own';
COMMENT ON COLUMN cortex.routines.deterministic IS 'true when the same arguments always give the same result; NULL when it says nothing';
COMMENT ON COLUMN cortex.routines.security IS 'whose rights it runs with, in the engine''s words (definer, invoker); NULL for the engine''s default';
COMMENT ON COLUMN cortex.routines.body IS 'its body, exactly as written';
