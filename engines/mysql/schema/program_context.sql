-- engine_mysql.program_context: what MySQL stores with each view and stored program, so its body means the same when written back.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.program_context (
  id                    TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the view, procedure, function, trigger, event or library
  definer               TEXT,                                                   -- the account whose rights it runs with (`app`@`%`); NULL when not written
  sql_mode              TEXT,                                                   -- the SQL mode it was created under; NULL for a view, and when not written
  character_set_client  TEXT,                                                   -- the character set its text was written in; NULL when not written
  collation_connection  TEXT,                                                   -- the collation it was created under; NULL when not written
  time_zone             TEXT,                                                   -- the time zone an event's schedule is read in; NULL for any other kind, and when not written
  follows               TEXT,                                                   -- the trigger a trigger runs after, by name; NULL for any other kind, and when not written
  precedes              TEXT,                                                   -- the trigger a trigger runs before, by name; NULL for any other kind, and when not written
  disabled_on_replica   BOOLEAN,                                                -- true for an event disabled on replicas only; NULL for any other kind
  CHECK (follows IS NULL OR precedes IS NULL)
);

COMMENT ON TABLE engine_mysql.program_context IS 'what MySQL stores with each view and stored program, so its body means the same when written back. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.program_context.id IS 'the view, procedure, function, trigger, event or library';
COMMENT ON COLUMN engine_mysql.program_context.definer IS 'the account whose rights it runs with (`app`@`%`); NULL when not written';
COMMENT ON COLUMN engine_mysql.program_context.sql_mode IS 'the SQL mode it was created under; NULL for a view, and when not written';
COMMENT ON COLUMN engine_mysql.program_context.character_set_client IS 'the character set its text was written in; NULL when not written';
COMMENT ON COLUMN engine_mysql.program_context.collation_connection IS 'the collation it was created under; NULL when not written';
COMMENT ON COLUMN engine_mysql.program_context.time_zone IS 'the time zone an event''s schedule is read in; NULL for any other kind, and when not written';
COMMENT ON COLUMN engine_mysql.program_context.follows IS 'the trigger a trigger runs after, by name; NULL for any other kind, and when not written';
COMMENT ON COLUMN engine_mysql.program_context.precedes IS 'the trigger a trigger runs before, by name; NULL for any other kind, and when not written';
COMMENT ON COLUMN engine_mysql.program_context.disabled_on_replica IS 'true for an event disabled on replicas only; NULL for any other kind';
