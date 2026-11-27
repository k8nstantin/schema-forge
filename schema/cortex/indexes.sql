-- cortex.indexes: the indexes of a table, in the order the server lists them, with what every engine says of an index; what only one engine says is its plugin's, with the same id.
CREATE TABLE cortex.indexes (
  id         UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row, kept when the name changes
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  object     UUID NOT NULL,                                                                                   -- the table it is on
  position   INTEGER NOT NULL CHECK (position >= 1),                                                          -- its place among the table's indexes, as the server lists them
  name       TEXT NOT NULL CHECK (length(name) >= 1),                                                         -- as the engine names it
  "unique"   BOOLEAN NOT NULL DEFAULT false,                                                                  -- true when no two rows may share its values
  method     TEXT,                                                                                            -- how it is built, in the engine's words (BTREE, FULLTEXT, gin); NULL for the engine's default
  condition  TEXT,                                                                                            -- the rows a partial index covers, as the engine writes it; NULL for all
  comment    TEXT,                                                                                            -- what it is for: written into its SQL
  UNIQUE (design, id),
  UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (object, position) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX indexes_object ON cortex.indexes (design, object);
