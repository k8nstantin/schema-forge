-- cortex.triggers: a trigger: when it fires, on which changes, for rows or statements, and what it runs. Owner: cortex.
CREATE TABLE cortex.triggers (
  id            BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the trigger; its table is the object's parent
  timing        TEXT NOT NULL CHECK (timing IN ('before', 'after', 'instead_of')),                                           -- when it fires
  events        JSONB NOT NULL,                                                                                              -- the changes it fires on, in order: ["insert", "update"]
  level         TEXT NOT NULL DEFAULT 'row' CHECK (level IN ('row', 'statement')),                                           -- once per row or once per statement
  condition     TEXT,                                                                                                        -- the rows it fires for, in the engine's SQL; NULL for every row
  body          TEXT,                                                                                                        -- the statements it runs, exactly as the server holds them; NULL where it calls a routine
  action_order  INTEGER NOT NULL DEFAULT 1 CHECK (action_order >= 1)                                                         -- its place among its table's triggers of the same timing and change
);

COMMENT ON TABLE cortex.triggers IS 'a trigger: when it fires, on which changes, for rows or statements, and what it runs.';
COMMENT ON COLUMN cortex.triggers.id IS 'the trigger; its table is the object''s parent';
COMMENT ON COLUMN cortex.triggers.timing IS 'when it fires';
COMMENT ON COLUMN cortex.triggers.events IS 'the changes it fires on, in order: ["insert", "update"]';
COMMENT ON COLUMN cortex.triggers.level IS 'once per row or once per statement';
COMMENT ON COLUMN cortex.triggers.condition IS 'the rows it fires for, in the engine''s SQL; NULL for every row';
COMMENT ON COLUMN cortex.triggers.body IS 'the statements it runs, exactly as the server holds them; NULL where it calls a routine';
COMMENT ON COLUMN cortex.triggers.action_order IS 'its place among its table''s triggers of the same timing and change';
