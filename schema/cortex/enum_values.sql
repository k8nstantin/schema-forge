-- cortex.enum_values: the values of an enumerated type, in order. Owner: cortex.
CREATE TABLE cortex.enum_values (
  id        UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  object    UUID NOT NULL,                                                                                 -- the type
  position  INTEGER NOT NULL CHECK (position >= 1),                                                        -- its place, 1 first
  value     TEXT NOT NULL,                                                                                 -- the value
  options   JSONB NOT NULL DEFAULT '{}',                                                                   -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}
  UNIQUE (object, value) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (object, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX enum_values_object ON cortex.enum_values (design, object);

COMMENT ON TABLE cortex.enum_values IS 'the values of an enumerated type, in order.';
COMMENT ON COLUMN cortex.enum_values.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.enum_values.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.enum_values.object IS 'the type';
COMMENT ON COLUMN cortex.enum_values.position IS 'its place, 1 first';
COMMENT ON COLUMN cortex.enum_values.value IS 'the value';
COMMENT ON COLUMN cortex.enum_values.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}';
