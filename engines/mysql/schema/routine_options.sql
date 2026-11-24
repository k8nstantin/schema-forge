-- engine_mysql.routine_options: what MySQL says of a procedure, function or library beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.routine_options (
  id           TEXT NOT NULL PRIMARY KEY REFERENCES cortex.routines (id) ON DELETE CASCADE,  -- the routine
  data_access  TEXT CHECK (data_access IN ('CONTAINS SQL', 'NO SQL', 'READS SQL DATA', 'MODIFIES SQL DATA'))  -- what it does with data; NULL when not written
);

COMMENT ON TABLE engine_mysql.routine_options IS 'what MySQL says of a procedure, function or library beyond the cortex. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.routine_options.id IS 'the routine';
COMMENT ON COLUMN engine_mysql.routine_options.data_access IS 'what it does with data; NULL when not written';
