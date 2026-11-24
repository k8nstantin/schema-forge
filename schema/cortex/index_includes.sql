-- cortex.index_includes: columns carried in an index without being part of its order. Owner: cortex.
CREATE TABLE cortex.index_includes (
  id        TEXT    NOT NULL PRIMARY KEY,                                       -- <index>.include<n>, n given once from id_counters and never reused: o_orders.index1.include1
  "index"   TEXT    NOT NULL REFERENCES cortex.indexes (id) ON DELETE CASCADE,  -- the index
  position  NUMERIC NOT NULL CHECK (position > 0),                              -- its place among the index's included columns; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  "column"  TEXT    NOT NULL REFERENCES cortex.columns (id) ON DELETE CASCADE,  -- a column of the index's table
  UNIQUE ("index", position),
  UNIQUE ("index", "column"),
  CHECK (substr(id, 1, length("index") + 8) = "index" || '.include' AND substr(id, length("index") + 9) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.index_includes IS 'columns carried in an index without being part of its order.';
COMMENT ON COLUMN cortex.index_includes.id IS '<index>.include<n>, n given once from id_counters and never reused: o_orders.index1.include1';
COMMENT ON COLUMN cortex.index_includes."index" IS 'the index';
COMMENT ON COLUMN cortex.index_includes.position IS 'its place among the index''s included columns; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.index_includes."column" IS 'a column of the index''s table';
