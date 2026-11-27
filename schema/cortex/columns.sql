-- cortex.columns: the columns of an object that has them (a table, a view), in order, with what every engine says of a column; what only one engine says is its plugin's, with the same id.
CREATE TABLE cortex.columns (
  id                    UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row, kept when the name changes
  design                UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  object                UUID NOT NULL,                                                                                   -- the object it belongs to
  position              INTEGER NOT NULL CHECK (position >= 1),                                                          -- its place in the object, as the server orders it: 1, 2, 3
  name                  TEXT NOT NULL CHECK (length(name) >= 1),                                                         -- as the engine names it (total)
  type                  TEXT NOT NULL CHECK (length(type) >= 1),                                                         -- its type as the engine writes it at the design's version (decimal(12,2))
  nullable              BOOLEAN NOT NULL,                                                                                -- true when it may hold null
  default_value         TEXT,                                                                                            -- its default as the engine writes it: a literal quoted, an expression as written; NULL for none
  generated_expression  TEXT,                                                                                            -- the expression it is computed from, as the engine writes it; NULL when not computed
  generated_stored      BOOLEAN,                                                                                         -- for a computed column, true when stored, false when computed as read; NULL otherwise
  "collation"           TEXT,                                                                                            -- its collation where it is not its object's, as the engine names it; NULL for the object's
  comment               TEXT,                                                                                            -- what it holds: written into its SQL
  UNIQUE (design, id),
  UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (object, position) DEFERRABLE INITIALLY DEFERRED,
  CHECK ((generated_expression IS NULL) = (generated_stored IS NULL)),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX columns_object ON cortex.columns (design, object);
