-- cortex.check_constraints: an expression every row of a table satisfies. Owner: cortex.
CREATE TABLE cortex.check_constraints (
  id          TEXT    NOT NULL PRIMARY KEY,                                       -- <object>.check<n>, n given once from id_counters and never reused: o_orders.check1
  object      TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the table or domain it is on
  position    NUMERIC NOT NULL CHECK (position > 0),                              -- its place among the object's checks; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name        TEXT,                                                               -- its constraint name; NULL for none
  expression  TEXT    NOT NULL CHECK (length(expression) >= 1),                   -- the expression, in the engine's SQL, exactly as written
  UNIQUE (object, position),
  CHECK (substr(id, 1, length(object) + 6) = object || '.check' AND substr(id, length(object) + 7) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.check_constraints IS 'an expression every row of a table satisfies.';
COMMENT ON COLUMN cortex.check_constraints.id IS '<object>.check<n>, n given once from id_counters and never reused: o_orders.check1';
COMMENT ON COLUMN cortex.check_constraints.object IS 'the table or domain it is on';
COMMENT ON COLUMN cortex.check_constraints.position IS 'its place among the object''s checks; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.check_constraints.name IS 'its constraint name; NULL for none';
COMMENT ON COLUMN cortex.check_constraints.expression IS 'the expression, in the engine''s SQL, exactly as written';
