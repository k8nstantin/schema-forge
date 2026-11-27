-- cortex.branches: the lines of work of a design; a design has its first, main, from when it is made, and its head is its newest committed turn.
CREATE TABLE cortex.branches (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  name        TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),                                            -- as people call it (main)
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),                                                              -- when it was made
  UNIQUE (design, id),
  UNIQUE (design, name)
);
