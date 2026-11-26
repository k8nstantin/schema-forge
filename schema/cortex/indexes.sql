-- cortex.indexes: an index of a table, in the order the table lists them. Owner: cortex.
CREATE TABLE cortex.indexes (
  id         UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  object     UUID NOT NULL,                                                                                 -- the table it is on
  position   NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place among the table's indexes: the server's order, which information_schema does not give; an order key: one put between two takes their midpoint, so nothing is renumbered
  name       TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- its name
  "unique"   BOOLEAN NOT NULL DEFAULT false,                                                                -- true for a unique index
  method     TEXT,                                                                                          -- how it is built, in the engine's words (BTREE, FULLTEXT, SPATIAL, gin); NULL for the engine's default
  condition  TEXT,                                                                                          -- the rows a partial index covers, in the engine's SQL; NULL for all
  comment    TEXT,                                                                                          -- what it is for; NULL for none
  parent     UUID,                                                                                          -- the partitioned table's index it is part of; NULL for none
  options    JSONB NOT NULL DEFAULT '{}',                                                                   -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}
  UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (object, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, parent) REFERENCES cortex.indexes (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX indexes_object ON cortex.indexes (design, object);
CREATE INDEX indexes_parent ON cortex.indexes (design, parent);

COMMENT ON TABLE cortex.indexes IS 'an index of a table, in the order the table lists them.';
COMMENT ON COLUMN cortex.indexes.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.indexes.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.indexes.object IS 'the table it is on';
COMMENT ON COLUMN cortex.indexes.position IS 'its place among the table''s indexes: the server''s order, which information_schema does not give; an order key: one put between two takes their midpoint, so nothing is renumbered';
COMMENT ON COLUMN cortex.indexes.name IS 'its name';
COMMENT ON COLUMN cortex.indexes."unique" IS 'true for a unique index';
COMMENT ON COLUMN cortex.indexes.method IS 'how it is built, in the engine''s words (BTREE, FULLTEXT, SPATIAL, gin); NULL for the engine''s default';
COMMENT ON COLUMN cortex.indexes.condition IS 'the rows a partial index covers, in the engine''s SQL; NULL for all';
COMMENT ON COLUMN cortex.indexes.comment IS 'what it is for; NULL for none';
COMMENT ON COLUMN cortex.indexes.parent IS 'the partitioned table''s index it is part of; NULL for none';
COMMENT ON COLUMN cortex.indexes.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}';
