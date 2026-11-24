-- cortex.indexes: an index of a table. Owner: cortex.
CREATE TABLE cortex.indexes (
  id         TEXT    NOT NULL PRIMARY KEY,                                       -- <object>.index<n>, n given once from id_counters and never reused: o_orders.index1
  object     TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the table it is on
  position   NUMERIC NOT NULL CHECK (position > 0),                              -- its place among the table's indexes; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name       TEXT    NOT NULL CHECK (length(name) >= 1),                         -- its name
  "unique"   BOOLEAN NOT NULL DEFAULT false,                                     -- true for a unique index
  method     TEXT,                                                               -- how it is built, in the engine's words (btree, fulltext, spatial); NULL for the engine's default
  condition  TEXT,                                                               -- the rows a partial index covers, in the engine's SQL; NULL for all
  UNIQUE (object, position),
  UNIQUE (object, name),
  CHECK (substr(id, 1, length(object) + 6) = object || '.index' AND substr(id, length(object) + 7) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.indexes IS 'an index of a table.';
COMMENT ON COLUMN cortex.indexes.id IS '<object>.index<n>, n given once from id_counters and never reused: o_orders.index1';
COMMENT ON COLUMN cortex.indexes.object IS 'the table it is on';
COMMENT ON COLUMN cortex.indexes.position IS 'its place among the table''s indexes; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.indexes.name IS 'its name';
COMMENT ON COLUMN cortex.indexes."unique" IS 'true for a unique index';
COMMENT ON COLUMN cortex.indexes.method IS 'how it is built, in the engine''s words (btree, fulltext, spatial); NULL for the engine''s default';
COMMENT ON COLUMN cortex.indexes.condition IS 'the rows a partial index covers, in the engine''s SQL; NULL for all';
