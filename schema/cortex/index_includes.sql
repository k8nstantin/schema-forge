-- index_includes: columns carried in an index without being part of its order. Owner: cortex.
CREATE TABLE index_includes (
  id        TEXT    NOT NULL PRIMARY KEY,                                      -- <index>.include<position>: o_orders.index1.include1
  "index"   TEXT    NOT NULL REFERENCES indexes (id) ON DELETE CASCADE,        -- the index
  position  INTEGER NOT NULL CHECK (position >= 1),                            -- its place among the index's included columns
  "column"  TEXT    NOT NULL REFERENCES columns (id) ON DELETE CASCADE,        -- a column of the index's table
  UNIQUE ("index", position),
  UNIQUE ("index", "column"),
  CHECK (id = "index" || '.include' || position)
) STRICT;
