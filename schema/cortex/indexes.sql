-- indexes: an index of a table. Owner: cortex.
CREATE TABLE indexes (
  id         TEXT    NOT NULL PRIMARY KEY,                                     -- <object>.index<position>: o_orders.index1
  object     TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,       -- the table it is on
  position   INTEGER NOT NULL CHECK (position >= 1),                           -- its place among the table's indexes
  name       TEXT    NOT NULL CHECK (length(name) >= 1),                       -- its name
  "unique"   INTEGER NOT NULL DEFAULT 0 CHECK ("unique" IN (0, 1)),            -- 1 for a unique index
  method     TEXT,                                                             -- how it is built, in the engine's words (btree, fulltext, spatial); NULL for the engine's default
  condition  TEXT,                                                             -- the rows a partial index covers, in the engine's SQL; NULL for all
  UNIQUE (object, position),
  UNIQUE (object, name),
  CHECK (id = object || '.index' || position)
) STRICT;
