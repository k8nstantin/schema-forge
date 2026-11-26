-- cortex.dependencies: what an object uses: a view's tables, a MERGE table's tables, a routine's tables where the engine says, the libraries a routine uses (MySQL 9.7's USING), in order. A used object cannot be dropped before what uses it, and an edit names what it would break; a body is text, so a rename never reaches into it. Owner: cortex.
CREATE TABLE cortex.dependencies (
  id        UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  object    UUID NOT NULL,                                                                                 -- the object that uses
  uses      UUID NOT NULL,                                                                                 -- the object used: it cannot go while this row is here
  position  NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  options   JSONB NOT NULL DEFAULT '{}',                                                                   -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"alias": "util"}
  UNIQUE (object, uses) DEFERRABLE INITIALLY DEFERRED,
  CHECK (object <> uses),
  UNIQUE (design, id),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, uses) REFERENCES cortex.objects (design, id) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX dependencies_object ON cortex.dependencies (design, object);
CREATE INDEX dependencies_uses ON cortex.dependencies (design, uses);

COMMENT ON TABLE cortex.dependencies IS 'what an object uses: a view''s tables, a MERGE table''s tables, a routine''s tables where the engine says, the libraries a routine uses (MySQL 9.7''s USING), in order. A used object cannot be dropped before what uses it, and an edit names what it would break; a body is text, so a rename never reaches into it.';
COMMENT ON COLUMN cortex.dependencies.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.dependencies.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.dependencies.object IS 'the object that uses';
COMMENT ON COLUMN cortex.dependencies.uses IS 'the object used: it cannot go while this row is here';
COMMENT ON COLUMN cortex.dependencies.position IS 'its place, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
COMMENT ON COLUMN cortex.dependencies.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"alias": "util"}';
