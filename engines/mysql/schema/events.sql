-- engine_mysql.events: a scheduled event: when it runs and what becomes of it. Owner: mysql.
CREATE TABLE engine_mysql.events (
  id              BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the event; its body is the object's
  body            TEXT NOT NULL,                                                                                               -- the statements it runs, exactly as SHOW CREATE EVENT holds them
  interval_value  TEXT,                                                                                                        -- EVERY's value as the server gives it (5, '1:30'); NULL for a one-time event
  interval_field  TEXT,                                                                                                        -- EVERY's unit (MINUTE, DAY, HOUR_MINUTE); NULL for a one-time event
  execute_at      TEXT,                                                                                                        -- a one-time event's moment, as the server writes it (2030-01-01 00:00:00), in its time zone; NULL for a recurring one
  starts          TEXT,                                                                                                        -- when a recurring event starts, as the server writes it; NULL when not written
  ends            TEXT,                                                                                                        -- when a recurring event ends, as the server writes it; NULL when not written
  status          TEXT NOT NULL CHECK (status IN ('ENABLE', 'DISABLE', 'DISABLE ON SLAVE', 'DISABLE ON REPLICA')),             -- whether it runs
  preserve        BOOLEAN NOT NULL DEFAULT false,                                                                              -- true when it is kept once its schedule is over
  CHECK ((interval_value IS NULL) = (execute_at IS NOT NULL))
);

COMMENT ON TABLE engine_mysql.events IS 'a scheduled event: when it runs and what becomes of it.';
COMMENT ON COLUMN engine_mysql.events.id IS 'the event; its body is the object''s';
COMMENT ON COLUMN engine_mysql.events.body IS 'the statements it runs, exactly as SHOW CREATE EVENT holds them';
COMMENT ON COLUMN engine_mysql.events.interval_value IS 'EVERY''s value as the server gives it (5, ''1:30''); NULL for a one-time event';
COMMENT ON COLUMN engine_mysql.events.interval_field IS 'EVERY''s unit (MINUTE, DAY, HOUR_MINUTE); NULL for a one-time event';
COMMENT ON COLUMN engine_mysql.events.execute_at IS 'a one-time event''s moment, as the server writes it (2030-01-01 00:00:00), in its time zone; NULL for a recurring one';
COMMENT ON COLUMN engine_mysql.events.starts IS 'when a recurring event starts, as the server writes it; NULL when not written';
COMMENT ON COLUMN engine_mysql.events.ends IS 'when a recurring event ends, as the server writes it; NULL when not written';
COMMENT ON COLUMN engine_mysql.events.status IS 'whether it runs';
COMMENT ON COLUMN engine_mysql.events.preserve IS 'true when it is kept once its schedule is over';
