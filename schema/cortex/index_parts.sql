-- cortex.index_parts: the parts of an index, in order: each a column of its table or an expression, in the order or only carried along.
CREATE TABLE cortex.index_parts (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  "index"     UUID NOT NULL,                                                                                   -- the index
  position    INTEGER NOT NULL CHECK (position >= 1),                                                          -- its place in the index: 1 first
  "column"    UUID,                                                                                            -- the column indexed; NULL for an expression
  expression  TEXT,                                                                                            -- the expression indexed, as the engine writes it; NULL for a column
  descending  BOOLEAN NOT NULL DEFAULT false,                                                                  -- true when held in descending order
  included    BOOLEAN NOT NULL DEFAULT false,                                                                  -- true for a column carried without being part of the order (INCLUDE)
  UNIQUE (design, id),
  UNIQUE ("index", position) DEFERRABLE INITIALLY DEFERRED,
  CHECK (("column" IS NULL) <> (expression IS NULL)),
  FOREIGN KEY (design, "index") REFERENCES cortex.indexes (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX index_parts_index ON cortex.index_parts (design, "index");
CREATE INDEX index_parts_column ON cortex.index_parts (design, "column");
