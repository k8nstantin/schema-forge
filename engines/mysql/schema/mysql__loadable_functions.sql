-- mysql__loadable_functions: a loadable function (CREATE FUNCTION name RETURNS type SONAME 'file').
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__loadable_functions (
  id         TEXT     NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the function
  soname     TEXT     NOT NULL CHECK (length(soname) >= 1),                -- the library file it is loaded from
  aggregate  INTEGER  NOT NULL DEFAULT 0 CHECK (aggregate IN (0, 1)),       -- 1 for an aggregate function
  returns    TEXT     NOT NULL CHECK (returns IN ('STRING', 'INTEGER', 'REAL', 'DECIMAL'))  -- what it returns
) STRICT;
