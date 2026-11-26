-- cortex.columns: the columns of a table, a view or a composite type, in order, with what every engine says of a column. Owner: cortex.
CREATE TABLE cortex.columns (
  id                    UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row, kept when the name changes
  design                UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  object                UUID NOT NULL,                                                                                 -- the object it belongs to
  position              NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place in the object: 1, 2, 3; an order key: one put between two takes their midpoint, so nothing is renumbered
  name                  TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- total
  type                  TEXT NOT NULL CHECK (length(type) >= 1),                                                       -- its type as the engine writes it at the schema's version (decimal(12,2), int(11) on MySQL 5.7)
  nullable              BOOLEAN NOT NULL,                                                                              -- true when it may hold null
  default_value         TEXT,                                                                                          -- its default, as the engine's SQL writes it: a literal quoted, an expression as written; NULL for none
  generated_expression  TEXT,                                                                                          -- the expression it is computed from, in the engine's SQL; NULL when it is not computed
  generated_stored      BOOLEAN,                                                                                       -- for a computed column: true when stored, false when computed when read
  "collation"           TEXT,                                                                                          -- its collation where it is not its table's, as the engine names it; NULL for the table's
  comment               TEXT,                                                                                          -- what it holds: written into its SQL
  options               JSONB NOT NULL DEFAULT '{}',                                                                   -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}
  UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (object, position) DEFERRABLE INITIALLY DEFERRED,
  CHECK ((generated_expression IS NULL) = (generated_stored IS NULL)),
  UNIQUE (design, id),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX columns_object ON cortex.columns (design, object);

COMMENT ON TABLE cortex.columns IS 'the columns of a table, a view or a composite type, in order, with what every engine says of a column.';
COMMENT ON COLUMN cortex.columns.id IS 'UUIDv7, made with the row, kept when the name changes';
COMMENT ON COLUMN cortex.columns.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.columns.object IS 'the object it belongs to';
COMMENT ON COLUMN cortex.columns.position IS 'its place in the object: 1, 2, 3; an order key: one put between two takes their midpoint, so nothing is renumbered';
COMMENT ON COLUMN cortex.columns.name IS 'total';
COMMENT ON COLUMN cortex.columns.type IS 'its type as the engine writes it at the schema''s version (decimal(12,2), int(11) on MySQL 5.7)';
COMMENT ON COLUMN cortex.columns.nullable IS 'true when it may hold null';
COMMENT ON COLUMN cortex.columns.default_value IS 'its default, as the engine''s SQL writes it: a literal quoted, an expression as written; NULL for none';
COMMENT ON COLUMN cortex.columns.generated_expression IS 'the expression it is computed from, in the engine''s SQL; NULL when it is not computed';
COMMENT ON COLUMN cortex.columns.generated_stored IS 'for a computed column: true when stored, false when computed when read';
COMMENT ON COLUMN cortex.columns."collation" IS 'its collation where it is not its table''s, as the engine names it; NULL for the table''s';
COMMENT ON COLUMN cortex.columns.comment IS 'what it holds: written into its SQL';
COMMENT ON COLUMN cortex.columns.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}';
