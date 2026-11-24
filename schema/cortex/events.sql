-- events: something the database runs on a schedule, with its body exactly as written. Owner: cortex.
CREATE TABLE events (
  id        TEXT    NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the event
  schedule  TEXT    NOT NULL CHECK (length(schedule) >= 1),                    -- when it runs, in the engine's SQL (EVERY 1 DAY STARTS '2027-01-01')
  preserve  INTEGER NOT NULL DEFAULT 0 CHECK (preserve IN (0, 1)),             -- 1 when it is kept once its schedule is over
  enabled   INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),              -- 1 when it runs
  body      TEXT    NOT NULL                                                   -- the statements it runs, exactly as written
) STRICT;
