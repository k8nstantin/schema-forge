-- cortex.index_parts: the parts of an index, in order: each a column or an expression, ordered or only included. Owner: cortex.
CREATE TABLE cortex.index_parts (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  "index"     UUID NOT NULL,                                                                                 -- the index
  position    NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  "column"    UUID,                                                                                          -- the column indexed; NULL for an expression
  expression  TEXT,                                                                                          -- the expression indexed, in the engine's SQL; NULL for a column
  descending  BOOLEAN NOT NULL DEFAULT false,                                                                -- true when held descending
  included    BOOLEAN NOT NULL DEFAULT false,                                                                -- true for a column carried without being part of the order (INCLUDE)
  options     JSONB NOT NULL DEFAULT '{}',                                                                   -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}
  UNIQUE ("index", position) DEFERRABLE INITIALLY DEFERRED,
  CHECK (("column" IS NULL) <> (expression IS NULL)),
  UNIQUE (design, id),
  FOREIGN KEY (design, "index") REFERENCES cortex.indexes (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX index_parts_index ON cortex.index_parts (design, "index");
CREATE INDEX index_parts_column ON cortex.index_parts (design, "column");

COMMENT ON TABLE cortex.index_parts IS 'the parts of an index, in order: each a column or an expression, ordered or only included.';
COMMENT ON COLUMN cortex.index_parts.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.index_parts.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.index_parts."index" IS 'the index';
COMMENT ON COLUMN cortex.index_parts.position IS 'its place, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
COMMENT ON COLUMN cortex.index_parts."column" IS 'the column indexed; NULL for an expression';
COMMENT ON COLUMN cortex.index_parts.expression IS 'the expression indexed, in the engine''s SQL; NULL for a column';
COMMENT ON COLUMN cortex.index_parts.descending IS 'true when held descending';
COMMENT ON COLUMN cortex.index_parts.included IS 'true for a column carried without being part of the order (INCLUDE)';
COMMENT ON COLUMN cortex.index_parts.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}';
