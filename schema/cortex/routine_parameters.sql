-- cortex.routine_parameters: the parameters of a routine, in order. Owner: cortex.
CREATE TABLE cortex.routine_parameters (
  id             TEXT    NOT NULL PRIMARY KEY,                                        -- <routine>.param<n>, n given once from id_counters and never reused: o_close_customer.param1
  routine        TEXT    NOT NULL REFERENCES cortex.routines (id) ON DELETE CASCADE,  -- the routine
  position       NUMERIC NOT NULL CHECK (position > 0),                               -- its place among the parameters; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name           TEXT    NOT NULL CHECK (length(name) >= 1),                          -- its name
  type           TEXT    NOT NULL CHECK (length(type) >= 1),                          -- its type, as the engine writes it
  mode           TEXT    CHECK (mode IN ('in', 'out', 'in_out')),                     -- how it is passed; NULL for in
  default_value  TEXT,                                                                -- its default, in the engine's SQL; NULL for none
  UNIQUE (routine, position),
  CHECK (substr(id, 1, length(routine) + 6) = routine || '.param' AND substr(id, length(routine) + 7) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.routine_parameters IS 'the parameters of a routine, in order.';
COMMENT ON COLUMN cortex.routine_parameters.id IS '<routine>.param<n>, n given once from id_counters and never reused: o_close_customer.param1';
COMMENT ON COLUMN cortex.routine_parameters.routine IS 'the routine';
COMMENT ON COLUMN cortex.routine_parameters.position IS 'its place among the parameters; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.routine_parameters.name IS 'its name';
COMMENT ON COLUMN cortex.routine_parameters.type IS 'its type, as the engine writes it';
COMMENT ON COLUMN cortex.routine_parameters.mode IS 'how it is passed; NULL for in';
COMMENT ON COLUMN cortex.routine_parameters.default_value IS 'its default, in the engine''s SQL; NULL for none';
