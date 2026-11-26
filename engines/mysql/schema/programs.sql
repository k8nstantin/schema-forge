-- engine_mysql.programs: what MySQL stores with each view, routine, trigger and event, and must be given again when it is written back, so its text means the same. Owner: mysql.
CREATE TABLE engine_mysql.programs (
  id                    UUID NOT NULL PRIMARY KEY,                                                                     -- the view, routine, trigger or event
  design                UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  definer               TEXT NOT NULL,                                                                                 -- the account whose rights it runs with, as the server gives it (app@%)
  sql_mode              TEXT,                                                                                          -- the SQL mode it was made under, from SHOW CREATE (5.7's ROUTINES misnames one mode); NULL for a view
  character_set_client  TEXT NOT NULL,                                                                                 -- the character set its text was written in: it is sent back in that character set
  collation_connection  TEXT NOT NULL,                                                                                 -- the collation it was made under
  database_collation    TEXT,                                                                                          -- its database's collation when it was made; NULL for a view
  time_zone             TEXT,                                                                                          -- the time zone an event's schedule is read in; NULL for any other kind
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_mysql.programs IS 'what MySQL stores with each view, routine, trigger and event, and must be given again when it is written back, so its text means the same.';
COMMENT ON COLUMN engine_mysql.programs.id IS 'the view, routine, trigger or event';
COMMENT ON COLUMN engine_mysql.programs.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_mysql.programs.definer IS 'the account whose rights it runs with, as the server gives it (app@%)';
COMMENT ON COLUMN engine_mysql.programs.sql_mode IS 'the SQL mode it was made under, from SHOW CREATE (5.7''s ROUTINES misnames one mode); NULL for a view';
COMMENT ON COLUMN engine_mysql.programs.character_set_client IS 'the character set its text was written in: it is sent back in that character set';
COMMENT ON COLUMN engine_mysql.programs.collation_connection IS 'the collation it was made under';
COMMENT ON COLUMN engine_mysql.programs.database_collation IS 'its database''s collation when it was made; NULL for a view';
COMMENT ON COLUMN engine_mysql.programs.time_zone IS 'the time zone an event''s schedule is read in; NULL for any other kind';
