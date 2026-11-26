-- engine_example.column_codecs: the codecs a column's values pass through, in order. Owner: example.
-- Shape 2, an ordered list: many rows per cortex row, each placed by an order key.
CREATE TABLE engine_example.column_codecs (
  id        UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  "column"  UUID NOT NULL,                                                                                 -- the column
  position  NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place among the column's codecs; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  codec     TEXT NOT NULL CHECK (codec IN ('delta', 'dictionary', 'zstd', 'lz4')),                         -- the codec
  level     INTEGER CHECK (level BETWEEN 1 AND 22),                                                        -- its level, for a codec that has one; NULL for its default
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  UNIQUE ("column", position),
  UNIQUE (design, id),
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE
);

CREATE INDEX column_codecs_column ON engine_example.column_codecs (design, "column");

COMMENT ON TABLE engine_example.column_codecs IS 'the codecs a column''s values pass through, in order. Shape 2, an ordered list: many rows per cortex row, each placed by an order key.';
COMMENT ON COLUMN engine_example.column_codecs.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_example.column_codecs.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_example.column_codecs."column" IS 'the column';
COMMENT ON COLUMN engine_example.column_codecs.position IS 'its place among the column''s codecs; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_example.column_codecs.codec IS 'the codec';
COMMENT ON COLUMN engine_example.column_codecs.level IS 'its level, for a codec that has one; NULL for its default';
