-- cortex.scheduled_events: something the database runs on a schedule, with its body exactly as written. Owner: cortex.
CREATE TABLE cortex.scheduled_events (
  id        TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the event
  schedule  TEXT    NOT NULL CHECK (length(schedule) >= 1),                                 -- when it runs, in the engine's SQL (EVERY 1 DAY STARTS '2027-01-01')
  preserve  BOOLEAN NOT NULL DEFAULT false,                                                 -- true when it is kept once its schedule is over
  enabled   BOOLEAN NOT NULL DEFAULT true,                                                  -- true when it runs
  body      TEXT    NOT NULL                                                                -- the statements it runs, exactly as written
);

COMMENT ON TABLE cortex.scheduled_events IS 'something the database runs on a schedule, with its body exactly as written.';
COMMENT ON COLUMN cortex.scheduled_events.id IS 'the event';
COMMENT ON COLUMN cortex.scheduled_events.schedule IS 'when it runs, in the engine''s SQL (EVERY 1 DAY STARTS ''2027-01-01'')';
COMMENT ON COLUMN cortex.scheduled_events.preserve IS 'true when it is kept once its schedule is over';
COMMENT ON COLUMN cortex.scheduled_events.enabled IS 'true when it runs';
COMMENT ON COLUMN cortex.scheduled_events.body IS 'the statements it runs, exactly as written';
