-- checks: an expression every row of a table satisfies. Owner: cortex.
CREATE TABLE checks (
  id          TEXT    NOT NULL PRIMARY KEY,                                    -- <object>.check<position>: o_orders.check1
  object      TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,      -- the table or domain it is on
  position    INTEGER NOT NULL CHECK (position >= 1),                          -- its place among the object's checks
  name        TEXT,                                                            -- its constraint name; NULL for none
  expression  TEXT    NOT NULL CHECK (length(expression) >= 1),                -- the expression, in the engine's SQL, exactly as written
  UNIQUE (object, position),
  CHECK (id = object || '.check' || position)
) STRICT;
