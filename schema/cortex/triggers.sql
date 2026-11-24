-- triggers: a trigger: when it fires, on which object, and its body exactly as written. Owner: cortex.
CREATE TABLE triggers (
  id         TEXT    NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the trigger
  timing     TEXT    NOT NULL CHECK (timing IN ('before', 'after', 'instead_of')),    -- when it fires
  "on"       TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,       -- the table or view it is on
  condition  TEXT,                                                             -- the rows it fires for, in the engine's SQL; NULL for every row
  body       TEXT    NOT NULL,                                                 -- the statements it runs, or the routine it calls, exactly as written
  CHECK (id <> "on")
) STRICT;
