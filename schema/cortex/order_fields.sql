-- order_fields: the order a table's rows are written in (a sort order, a clustering). Owner: cortex.
CREATE TABLE order_fields (
  id         TEXT    NOT NULL PRIMARY KEY,                                     -- <object>.order<position>: o_events.order1
  object     TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,       -- the table
  position   INTEGER NOT NULL CHECK (position >= 1),                           -- its place in the order
  "column"   TEXT    NOT NULL REFERENCES columns (id) ON DELETE CASCADE,       -- the column ordered by
  transform  TEXT,                                                             -- the transform, in the engine's words; NULL for the value itself
  direction  TEXT    CHECK (direction IN ('asc', 'desc')),                     -- NULL for the engine's default
  nulls      TEXT    CHECK (nulls IN ('first', 'last')),                       -- NULL for the engine's default
  UNIQUE (object, position),
  CHECK (id = object || '.order' || position)
) STRICT;
