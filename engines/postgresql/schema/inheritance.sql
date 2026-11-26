-- engine_postgresql.inheritance: the tables a table inherits from, in order (INHERITS); partitions are cortex.partitions. Owner: postgresql.
CREATE TABLE engine_postgresql.inheritance (
  id        UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  object    UUID NOT NULL,                                                                                 -- the table that inherits
  parent    UUID NOT NULL,                                                                                 -- the table inherited from: it cannot go first
  position  INTEGER NOT NULL CHECK (position >= 1),                                                        -- its place, 1 first
  UNIQUE (object, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, parent) REFERENCES cortex.objects (design, id) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX inheritance_object ON engine_postgresql.inheritance (design, object);
CREATE INDEX inheritance_parent ON engine_postgresql.inheritance (design, parent);

COMMENT ON TABLE engine_postgresql.inheritance IS 'the tables a table inherits from, in order (INHERITS); partitions are cortex.partitions.';
COMMENT ON COLUMN engine_postgresql.inheritance.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.inheritance.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.inheritance.object IS 'the table that inherits';
COMMENT ON COLUMN engine_postgresql.inheritance.parent IS 'the table inherited from: it cannot go first';
COMMENT ON COLUMN engine_postgresql.inheritance.position IS 'its place, 1 first';
