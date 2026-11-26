-- cortex.sort_fields: the order a table's rows are written in (a sort order, a clustering). Owner: cortex.
CREATE TABLE cortex.sort_fields (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  object      UUID NOT NULL,                                                                                 -- the table
  position    INTEGER NOT NULL CHECK (position >= 1),                                                        -- its place, 1 first
  "column"    UUID NOT NULL,                                                                                 -- the column ordered by
  transform   TEXT,                                                                                          -- the transform, in the engine's words; NULL for the value itself
  descending  BOOLEAN NOT NULL DEFAULT false,                                                                -- true when descending
  UNIQUE (object, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX sort_fields_object ON cortex.sort_fields (design, object);
CREATE INDEX sort_fields_column ON cortex.sort_fields (design, "column");

COMMENT ON TABLE cortex.sort_fields IS 'the order a table''s rows are written in (a sort order, a clustering).';
COMMENT ON COLUMN cortex.sort_fields.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.sort_fields.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.sort_fields.object IS 'the table';
COMMENT ON COLUMN cortex.sort_fields.position IS 'its place, 1 first';
COMMENT ON COLUMN cortex.sort_fields."column" IS 'the column ordered by';
COMMENT ON COLUMN cortex.sort_fields.transform IS 'the transform, in the engine''s words; NULL for the value itself';
COMMENT ON COLUMN cortex.sort_fields.descending IS 'true when descending';
