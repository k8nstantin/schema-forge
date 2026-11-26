-- cortex.object_tags: the tags of an object (scd2, pii), in order. Owner: cortex.
CREATE TABLE cortex.object_tags (
  id        UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  object    UUID NOT NULL,                                                                                 -- the object tagged
  position  INTEGER NOT NULL CHECK (position >= 1),                                                        -- its place, 1 first
  tag       TEXT NOT NULL CHECK (length(tag) >= 1),                                                        -- the tag
  UNIQUE (object, tag) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX object_tags_object ON cortex.object_tags (design, object);

COMMENT ON TABLE cortex.object_tags IS 'the tags of an object (scd2, pii), in order.';
COMMENT ON COLUMN cortex.object_tags.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.object_tags.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.object_tags.object IS 'the object tagged';
COMMENT ON COLUMN cortex.object_tags.position IS 'its place, 1 first';
COMMENT ON COLUMN cortex.object_tags.tag IS 'the tag';
