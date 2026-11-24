-- cortex.triggers: a trigger: when it fires, on which object, and its body exactly as written. Owner: cortex.
CREATE TABLE cortex.triggers (
  id         TEXT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the trigger
  timing     TEXT NOT NULL CHECK (timing IN ('before', 'after', 'instead_of')),           -- when it fires
  "on"       TEXT NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,              -- the table or view it is on
  condition  TEXT,                                                                        -- the rows it fires for, in the engine's SQL; NULL for every row
  body       TEXT NOT NULL,                                                               -- the statements it runs, or the routine it calls, exactly as written
  CHECK (id <> "on")
);

COMMENT ON TABLE cortex.triggers IS 'a trigger: when it fires, on which object, and its body exactly as written.';
COMMENT ON COLUMN cortex.triggers.id IS 'the trigger';
COMMENT ON COLUMN cortex.triggers.timing IS 'when it fires';
COMMENT ON COLUMN cortex.triggers."on" IS 'the table or view it is on';
COMMENT ON COLUMN cortex.triggers.condition IS 'the rows it fires for, in the engine''s SQL; NULL for every row';
COMMENT ON COLUMN cortex.triggers.body IS 'the statements it runs, or the routine it calls, exactly as written';
