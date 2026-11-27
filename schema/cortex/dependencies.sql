-- cortex.dependencies: what an object uses, and as what (a view's tables, a trigger's function, a routine's tables where the engine says): what the canvas draws as lineage and the agent follows as impact; a used object cannot go while what uses it stays.
CREATE TABLE cortex.dependencies (
  id      UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row
  design  UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  object  UUID NOT NULL,                                                                                   -- the object that uses
  uses    UUID NOT NULL,                                                                                   -- the object used
  "as"    TEXT NOT NULL CHECK ("as" ~ '^[a-z][a-z0-9_]*$'),                                                -- the part it plays, as the engine names it (reads, calls, function, type)
  UNIQUE (design, id),
  UNIQUE (object, uses, "as") DEFERRABLE INITIALLY DEFERRED,
  CHECK (object <> uses),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, uses) REFERENCES cortex.objects (design, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX dependencies_object ON cortex.dependencies (design, object);
CREATE INDEX dependencies_uses ON cortex.dependencies (design, uses);
