-- cortex.routines: a procedure or a function: what it returns, how it runs, and its body exactly as the server holds it. Owner: cortex.
CREATE TABLE cortex.routines (
  id             UUID NOT NULL PRIMARY KEY,                                                                     -- the routine
  design         UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  returns        TEXT,                                                                                          -- what a function returns, as the engine writes the type; NULL for a procedure
  language       TEXT,                                                                                          -- its language in the engine's words (SQL, plpgsql); NULL for the engine's own
  deterministic  BOOLEAN NOT NULL DEFAULT false,                                                                -- true when the same arguments always give the same result
  security       TEXT NOT NULL DEFAULT 'definer' CHECK (security IN ('definer', 'invoker')),                    -- whose rights it runs with
  body           TEXT NOT NULL,                                                                                 -- its body, exactly as the server holds it (SHOW CREATE, prosrc): information_schema's copy is not it
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE cortex.routines IS 'a procedure or a function: what it returns, how it runs, and its body exactly as the server holds it.';
COMMENT ON COLUMN cortex.routines.id IS 'the routine';
COMMENT ON COLUMN cortex.routines.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.routines.returns IS 'what a function returns, as the engine writes the type; NULL for a procedure';
COMMENT ON COLUMN cortex.routines.language IS 'its language in the engine''s words (SQL, plpgsql); NULL for the engine''s own';
COMMENT ON COLUMN cortex.routines.deterministic IS 'true when the same arguments always give the same result';
COMMENT ON COLUMN cortex.routines.security IS 'whose rights it runs with';
COMMENT ON COLUMN cortex.routines.body IS 'its body, exactly as the server holds it (SHOW CREATE, prosrc): information_schema''s copy is not it';
