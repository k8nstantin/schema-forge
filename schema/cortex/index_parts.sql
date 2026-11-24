-- cortex.index_parts: the parts of an index, in order: each a column or an expression. Owner: cortex.
CREATE TABLE cortex.index_parts (
  id          TEXT    NOT NULL PRIMARY KEY,                                       -- <index>.<n>, n given once from id_counters and never reused: o_orders.index1.1
  "index"     TEXT    NOT NULL REFERENCES cortex.indexes (id) ON DELETE CASCADE,  -- the index
  position    NUMERIC NOT NULL CHECK (position > 0),                              -- the part's place in the index; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  "column"    TEXT    REFERENCES cortex.columns (id) ON DELETE CASCADE,           -- the column indexed; NULL for an expression
  expression  TEXT,                                                               -- the expression indexed, in the engine's SQL; NULL for a column
  direction   TEXT    CHECK (direction IN ('asc', 'desc')),                       -- its order; NULL for the engine's default
  nulls       TEXT    CHECK (nulls IN ('first', 'last')),                         -- where nulls sort; NULL for the engine's default
  UNIQUE ("index", position),
  CHECK (("column" IS NULL) <> (expression IS NULL)),
  CHECK (substr(id, 1, length("index") + 1) = "index" || '.' AND substr(id, length("index") + 2) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.index_parts IS 'the parts of an index, in order: each a column or an expression.';
COMMENT ON COLUMN cortex.index_parts.id IS '<index>.<n>, n given once from id_counters and never reused: o_orders.index1.1';
COMMENT ON COLUMN cortex.index_parts."index" IS 'the index';
COMMENT ON COLUMN cortex.index_parts.position IS 'the part''s place in the index; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.index_parts."column" IS 'the column indexed; NULL for an expression';
COMMENT ON COLUMN cortex.index_parts.expression IS 'the expression indexed, in the engine''s SQL; NULL for a column';
COMMENT ON COLUMN cortex.index_parts.direction IS 'its order; NULL for the engine''s default';
COMMENT ON COLUMN cortex.index_parts.nulls IS 'where nulls sort; NULL for the engine''s default';
