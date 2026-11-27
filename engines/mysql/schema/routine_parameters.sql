-- engine_mysql.routine_parameters: the parameters of a procedure or function, in order, each as written.
CREATE TABLE engine_mysql.routine_parameters (
  id        UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  routine   UUID NOT NULL,                                                                                   -- the routine
  position  INTEGER NOT NULL CHECK (position >= 1),                                                          -- its place: 1 first
  mode      TEXT CHECK (mode IN ('IN', 'OUT', 'INOUT')),                                                     -- IN, OUT or INOUT, for a procedure's; NULL for a function's
  name      TEXT NOT NULL CHECK (length(name) >= 1),                                                         -- as written
  type      TEXT NOT NULL CHECK (length(type) >= 1),                                                         -- its type as written (varchar(64) CHARSET utf8mb4)
  UNIQUE (design, id),
  UNIQUE (routine, position) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, routine) REFERENCES engine_mysql.routines (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX routine_parameters_routine ON engine_mysql.routine_parameters (design, routine);
