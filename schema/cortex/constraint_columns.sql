-- cortex.constraint_columns: the columns of a key or a link, in order; for a link, each with the column it refers to. Owner: cortex.
CREATE TABLE cortex.constraint_columns (
  id              UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design          UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  "constraint"    UUID NOT NULL,                                                                                 -- the key or link
  position        INTEGER NOT NULL CHECK (position >= 1),                                                        -- its place, 1 first
  "column"        UUID NOT NULL,                                                                                 -- a column of the constraint's table
  to_column       UUID,                                                                                          -- the column a link refers to; NULL for a key, and for a table outside the store
  to_column_name  TEXT,                                                                                          -- the referred column outside the store, as written; NULL otherwise
  UNIQUE ("constraint", position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, "constraint") REFERENCES cortex.constraints (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, to_column) REFERENCES cortex.columns (design, id) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX constraint_columns_constraint ON cortex.constraint_columns (design, "constraint");
CREATE INDEX constraint_columns_column ON cortex.constraint_columns (design, "column");
CREATE INDEX constraint_columns_to_column ON cortex.constraint_columns (design, to_column);

COMMENT ON TABLE cortex.constraint_columns IS 'the columns of a key or a link, in order; for a link, each with the column it refers to.';
COMMENT ON COLUMN cortex.constraint_columns.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.constraint_columns.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.constraint_columns."constraint" IS 'the key or link';
COMMENT ON COLUMN cortex.constraint_columns.position IS 'its place, 1 first';
COMMENT ON COLUMN cortex.constraint_columns."column" IS 'a column of the constraint''s table';
COMMENT ON COLUMN cortex.constraint_columns.to_column IS 'the column a link refers to; NULL for a key, and for a table outside the store';
COMMENT ON COLUMN cortex.constraint_columns.to_column_name IS 'the referred column outside the store, as written; NULL otherwise';
