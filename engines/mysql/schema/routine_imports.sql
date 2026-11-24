-- engine_mysql.routine_imports: the libraries a routine uses (USING (lib1, lib2)), in order.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.routine_imports (
  id        TEXT    NOT NULL PRIMARY KEY,                                        -- <routine>.import<n>, n given once from id_counters and never reused
  routine   TEXT    NOT NULL REFERENCES cortex.routines (id) ON DELETE CASCADE,  -- the routine
  position  NUMERIC NOT NULL CHECK (position > 0),                               -- its place in USING; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  library   TEXT    NOT NULL CHECK (length(library) >= 1),                       -- the library, as written
  UNIQUE (routine, position),
  CHECK (substr(id, 1, length(routine) + 7) = routine || '.import' AND substr(id, length(routine) + 8) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_mysql.routine_imports IS 'the libraries a routine uses (USING (lib1, lib2)), in order. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.routine_imports.id IS '<routine>.import<n>, n given once from id_counters and never reused';
COMMENT ON COLUMN engine_mysql.routine_imports.routine IS 'the routine';
COMMENT ON COLUMN engine_mysql.routine_imports.position IS 'its place in USING; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_mysql.routine_imports.library IS 'the library, as written';
