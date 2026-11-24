-- engine_example.column_codecs: the codecs a column's values pass through, in order. Owner: example.
-- Shape 2, an ordered list: many rows per cortex row, each numbered from id_counters and placed by an order key.
CREATE TABLE engine_example.column_codecs (
  id        TEXT    NOT NULL PRIMARY KEY,                                              -- <column>.codec<n>, n given once from id_counters and never reused: c_orders_total.codec1
  "column"  TEXT    NOT NULL REFERENCES cortex.columns (id) ON DELETE CASCADE,         -- the column
  position  NUMERIC NOT NULL CHECK (position > 0),                                     -- its place among the column's codecs; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  codec     TEXT    NOT NULL CHECK (codec IN ('delta', 'dictionary', 'zstd', 'lz4')),  -- the codec
  level     INTEGER CHECK (level BETWEEN 1 AND 22),                                    -- its level, for a codec that has one; NULL for its default
  UNIQUE ("column", position),
  CHECK (substr(id, 1, length("column") + 6) = "column" || '.codec' AND substr(id, length("column") + 7) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_example.column_codecs IS 'the codecs a column''s values pass through, in order. Shape 2, an ordered list: many rows per cortex row, each numbered from id_counters and placed by an order key.';
COMMENT ON COLUMN engine_example.column_codecs.id IS '<column>.codec<n>, n given once from id_counters and never reused: c_orders_total.codec1';
COMMENT ON COLUMN engine_example.column_codecs."column" IS 'the column';
COMMENT ON COLUMN engine_example.column_codecs.position IS 'its place among the column''s codecs; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_example.column_codecs.codec IS 'the codec';
COMMENT ON COLUMN engine_example.column_codecs.level IS 'its level, for a codec that has one; NULL for its default';
