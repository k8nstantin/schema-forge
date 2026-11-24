-- mysql__routine_options: what MySQL says of a procedure, function or library beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__routine_options (
  id           TEXT  NOT NULL PRIMARY KEY REFERENCES routines (id) ON DELETE CASCADE,  -- the routine
  data_access  TEXT  CHECK (data_access IN ('CONTAINS SQL', 'NO SQL', 'READS SQL DATA', 'MODIFIES SQL DATA'))  -- what it does with data; NULL when not written
) STRICT;
