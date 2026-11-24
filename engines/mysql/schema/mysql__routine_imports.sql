-- mysql__routine_imports: the libraries a routine uses (USING (lib1, lib2)), in order.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__routine_imports (
  id        TEXT    NOT NULL PRIMARY KEY,                                    -- <routine>.import<position>
  routine   TEXT    NOT NULL REFERENCES routines (id) ON DELETE CASCADE,     -- the routine
  position  INTEGER NOT NULL CHECK (position >= 1),                          -- its place in USING
  library   TEXT    NOT NULL CHECK (length(library) >= 1),                   -- the library, as written
  UNIQUE (routine, position),
  CHECK (id = routine || '.import' || position)
) STRICT;
