-- engine_postgresql.triggers: what PostgreSQL says of a trigger beyond the cortex. Owner: postgresql.
CREATE TABLE engine_postgresql.triggers (
  id              BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.triggers (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the trigger
  function_name   TEXT NOT NULL,                                                                                                -- the trigger function, as the server names it (audit.log_change)
  arguments       JSONB,                                                                                                        -- the arguments passed to it; NULL for none
  update_columns  JSONB,                                                                                                        -- UPDATE OF: the ids of the columns it fires on; NULL for any
  old_table       TEXT,                                                                                                         -- the transition table of old rows (REFERENCING OLD TABLE AS); NULL for none
  new_table       TEXT,                                                                                                         -- the transition table of new rows; NULL for none
  enabled         TEXT NOT NULL DEFAULT 'origin' CHECK (enabled IN ('origin', 'disabled', 'replica', 'always'))                 -- when it fires
);

COMMENT ON TABLE engine_postgresql.triggers IS 'what PostgreSQL says of a trigger beyond the cortex.';
COMMENT ON COLUMN engine_postgresql.triggers.id IS 'the trigger';
COMMENT ON COLUMN engine_postgresql.triggers.function_name IS 'the trigger function, as the server names it (audit.log_change)';
COMMENT ON COLUMN engine_postgresql.triggers.arguments IS 'the arguments passed to it; NULL for none';
COMMENT ON COLUMN engine_postgresql.triggers.update_columns IS 'UPDATE OF: the ids of the columns it fires on; NULL for any';
COMMENT ON COLUMN engine_postgresql.triggers.old_table IS 'the transition table of old rows (REFERENCING OLD TABLE AS); NULL for none';
COMMENT ON COLUMN engine_postgresql.triggers.new_table IS 'the transition table of new rows; NULL for none';
COMMENT ON COLUMN engine_postgresql.triggers.enabled IS 'when it fires';
