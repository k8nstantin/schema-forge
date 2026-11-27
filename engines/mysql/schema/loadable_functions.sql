-- engine_mysql.loadable_functions: a loadable function installed on the server (CREATE FUNCTION ... SONAME): what it returns and the library it is in.
CREATE TABLE engine_mysql.loadable_functions (
  id         UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  returns    TEXT NOT NULL CHECK (returns IN ('STRING', 'INTEGER', 'REAL', 'DECIMAL')),                        -- RETURNS
  aggregate  BOOLEAN NOT NULL DEFAULT false,                                                                  -- AGGREGATE
  library    TEXT NOT NULL CHECK (length(library) >= 1),                                                      -- SONAME, the library file
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
