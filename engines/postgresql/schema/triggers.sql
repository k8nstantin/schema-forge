-- engine_postgresql.triggers: what PostgreSQL says of a trigger beyond the cortex. Owner: postgresql.
CREATE TABLE engine_postgresql.triggers (
  id              UUID NOT NULL PRIMARY KEY,                                                                      -- the trigger
  design          UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,   -- the design it belongs to
  function_name   TEXT NOT NULL,                                                                                  -- the trigger function, as the server names it (audit.log_change)
  arguments       JSONB,                                                                                          -- the arguments passed to it; NULL for none
  update_columns  JSONB,                                                                                          -- UPDATE OF: the ids of the columns it fires on; NULL for any
  old_table       TEXT,                                                                                           -- the transition table of old rows (REFERENCING OLD TABLE AS); NULL for none
  new_table       TEXT,                                                                                           -- the transition table of new rows; NULL for none
  enabled         TEXT NOT NULL DEFAULT 'origin' CHECK (enabled IN ('origin', 'disabled', 'replica', 'always')),  -- when it fires
  constraint_trigger  BOOLEAN NOT NULL DEFAULT false,  -- made by CREATE CONSTRAINT TRIGGER: it fires after the change, and may wait for the commit
  from_table      TEXT,  -- the table a constraint trigger names in FROM, as the server writes it; NULL for none
  "deferrable"    BOOLEAN NOT NULL DEFAULT false,  -- a constraint trigger that may wait for the commit (DEFERRABLE)
  initially_deferred  BOOLEAN NOT NULL DEFAULT false,  -- a deferrable one that waits for the commit unless told otherwise (INITIALLY DEFERRED)
  CHECK ("deferrable" OR NOT initially_deferred),
  CHECK (constraint_trigger OR NOT ("deferrable" OR from_table IS NOT NULL)),
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.triggers (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_postgresql.triggers IS 'what PostgreSQL says of a trigger beyond the cortex.';
COMMENT ON COLUMN engine_postgresql.triggers.id IS 'the trigger';
COMMENT ON COLUMN engine_postgresql.triggers.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.triggers.function_name IS 'the trigger function, as the server names it (audit.log_change)';
COMMENT ON COLUMN engine_postgresql.triggers.arguments IS 'the arguments passed to it; NULL for none';
COMMENT ON COLUMN engine_postgresql.triggers.update_columns IS 'UPDATE OF: the ids of the columns it fires on; NULL for any';
COMMENT ON COLUMN engine_postgresql.triggers.old_table IS 'the transition table of old rows (REFERENCING OLD TABLE AS); NULL for none';
COMMENT ON COLUMN engine_postgresql.triggers.new_table IS 'the transition table of new rows; NULL for none';
COMMENT ON COLUMN engine_postgresql.triggers.enabled IS 'when it fires';
COMMENT ON COLUMN engine_postgresql.triggers.constraint_trigger IS 'made by CREATE CONSTRAINT TRIGGER: it fires after the change, and may wait for the commit';
COMMENT ON COLUMN engine_postgresql.triggers.from_table IS 'the table a constraint trigger names in FROM, as the server writes it; NULL for none';
COMMENT ON COLUMN engine_postgresql.triggers."deferrable" IS 'a constraint trigger that may wait for the commit (DEFERRABLE)';
COMMENT ON COLUMN engine_postgresql.triggers.initially_deferred IS 'a deferrable one that waits for the commit unless told otherwise (INITIALLY DEFERRED)';
