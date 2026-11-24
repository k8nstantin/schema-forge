-- engine_mysql.loadable_functions: a loadable function (CREATE FUNCTION name RETURNS type SONAME 'file').
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.loadable_functions (
  id         TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the function
  soname     TEXT    NOT NULL CHECK (length(soname) >= 1),                                   -- the library file it is loaded from
  aggregate  BOOLEAN NOT NULL DEFAULT false,                                                 -- true for an aggregate function
  returns    TEXT    NOT NULL CHECK (returns IN ('STRING', 'INTEGER', 'REAL', 'DECIMAL'))    -- what it returns
);

COMMENT ON TABLE engine_mysql.loadable_functions IS 'a loadable function (CREATE FUNCTION name RETURNS type SONAME ''file''). Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.loadable_functions.id IS 'the function';
COMMENT ON COLUMN engine_mysql.loadable_functions.soname IS 'the library file it is loaded from';
COMMENT ON COLUMN engine_mysql.loadable_functions.aggregate IS 'true for an aggregate function';
COMMENT ON COLUMN engine_mysql.loadable_functions.returns IS 'what it returns';
