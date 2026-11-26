-- engine_mysql.routines: what MySQL says of a procedure or function beyond the cortex. Owner: mysql.
CREATE TABLE engine_mysql.routines (
  id                   UUID NOT NULL PRIMARY KEY,                                                                                                      -- the routine
  design               UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,                                   -- the design it belongs to
  parameter_text       TEXT NOT NULL,                                                                                                                  -- its parameter list exactly as written: real code formats it by hand, so it is not rebuilt from the parameters
  data_access          TEXT NOT NULL DEFAULT 'CONTAINS SQL' CHECK (data_access IN ('CONTAINS SQL', 'NO SQL', 'READS SQL DATA', 'MODIFIES SQL DATA')),  -- what it does with data
  returns_charset      TEXT,                                                                                                                           -- a function's result character set (RETURNS varchar(10) CHARSET latin1); NULL for none
  parameter_collation  TEXT,                                                                                                                           -- the collation its parameters without a character set took: the current database's when it was made, not always its own
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.routines (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_mysql.routines IS 'what MySQL says of a procedure or function beyond the cortex.';
COMMENT ON COLUMN engine_mysql.routines.id IS 'the routine';
COMMENT ON COLUMN engine_mysql.routines.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_mysql.routines.parameter_text IS 'its parameter list exactly as written: real code formats it by hand, so it is not rebuilt from the parameters';
COMMENT ON COLUMN engine_mysql.routines.data_access IS 'what it does with data';
COMMENT ON COLUMN engine_mysql.routines.returns_charset IS 'a function''s result character set (RETURNS varchar(10) CHARSET latin1); NULL for none';
COMMENT ON COLUMN engine_mysql.routines.parameter_collation IS 'the collation its parameters without a character set took: the current database''s when it was made, not always its own';
