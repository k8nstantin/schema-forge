-- engine_mysql.events: a scheduled event: its schedule, what it does once it completes, its body as the server holds it, and the context it was made in.
CREATE TABLE engine_mysql.events (
  id                    UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design                UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  execute_at            TEXT,                                                                                            -- AT, for an event that runs once, as written; NULL for a recurring one
  interval_value        TEXT,                                                                                            -- EVERY's number, as written; NULL for one that runs once
  interval_field        TEXT,                                                                                            -- EVERY's unit (DAY, HOUR, MINUTE_SECOND)
  starts                TEXT,                                                                                            -- STARTS, as written; NULL for none
  ends                  TEXT,                                                                                            -- ENDS, as written; NULL for none
  on_completion         TEXT NOT NULL DEFAULT 'NOT PRESERVE' CHECK (on_completion IN ('PRESERVE', 'NOT PRESERVE')),      -- ON COMPLETION
  status                TEXT NOT NULL DEFAULT 'ENABLE' CHECK (status IN ('ENABLE', 'DISABLE', 'DISABLE ON SLAVE', 'DISABLE ON REPLICA')),  -- its status as written
  body                  TEXT NOT NULL,                                                                                   -- its body, exactly as SHOW CREATE EVENT writes it
  definer               TEXT NOT NULL,                                                                                   -- DEFINER, as written
  time_zone             TEXT NOT NULL,                                                                                   -- the time zone it was made in
  sql_mode              TEXT NOT NULL,                                                                                   -- the SQL mode it was made under
  character_set_client  TEXT NOT NULL,                                                                                   -- the client character set it was made with
  collation_connection  TEXT NOT NULL,                                                                                   -- the connection collation it was made with
  database_collation    TEXT NOT NULL,                                                                                   -- its database's collation when it was made
  UNIQUE (design, id),
  CHECK ((execute_at IS NULL) <> (interval_value IS NULL)),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
