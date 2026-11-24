-- parameters: the parameters of a routine, in order. Owner: cortex.
CREATE TABLE parameters (
  id             TEXT    NOT NULL PRIMARY KEY,                                 -- <routine>.param<position>: o_close_customer.param1
  routine        TEXT    NOT NULL REFERENCES routines (id) ON DELETE CASCADE,  -- the routine
  position       INTEGER NOT NULL CHECK (position >= 1),                       -- its place among the parameters
  name           TEXT    NOT NULL CHECK (length(name) >= 1),                   -- its name
  type           TEXT    NOT NULL CHECK (length(type) >= 1),                   -- its type, as the engine writes it
  mode           TEXT    CHECK (mode IN ('in', 'out', 'in_out')),              -- how it is passed; NULL for in
  default_value  TEXT,                                                         -- its default, in the engine's SQL; NULL for none
  UNIQUE (routine, position),
  CHECK (id = routine || '.param' || position)
) STRICT;
