-- index_parts: the parts of an index, in order: each a column or an expression. Owner: cortex.
CREATE TABLE index_parts (
  id          TEXT    NOT NULL PRIMARY KEY,                                    -- <index>.<position>: o_orders.index1.1
  "index"     TEXT    NOT NULL REFERENCES indexes (id) ON DELETE CASCADE,      -- the index
  position    INTEGER NOT NULL CHECK (position >= 1),                          -- the part's place in the index
  "column"    TEXT    REFERENCES columns (id) ON DELETE CASCADE,               -- the column indexed; NULL for an expression
  expression  TEXT,                                                            -- the expression indexed, in the engine's SQL; NULL for a column
  direction   TEXT    CHECK (direction IN ('asc', 'desc')),                    -- its order; NULL for the engine's default
  nulls       TEXT    CHECK (nulls IN ('first', 'last')),                      -- where nulls sort; NULL for the engine's default
  UNIQUE ("index", position),
  CHECK (("column" IS NULL) <> (expression IS NULL)),
  CHECK (id = "index" || '.' || position)
) STRICT;
