-- cortex.designs: every design people work on here, each the rows of these tables that point at it: never a database, a schema or a table of its own. Owner: cortex.
CREATE TABLE cortex.designs (
  id              UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),  -- UUIDv7, issued when it is made, never changed: how everything names the design
  name            TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 100),                      -- as people call it (shop); a rename changes this and nothing else
  engine          TEXT NOT NULL,                                                                    -- the id of the engine it is designed for, as the registry knows it (mysql)
  engine_version  TEXT NOT NULL,                                                                    -- one of the engine's versions; it decides which features the design is offered (8.4)
  flavor          TEXT,                                                                             -- the managed flavor of its engine it is designed for (mysql/rds, postgresql/alloydb); NULL for the engine's own server
  comment         TEXT,                                                                             -- what the design is for, in a sentence or two
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),                                               -- when it was made
  FOREIGN KEY (flavor) REFERENCES cortex.engine_flavors (id) DEFERRABLE INITIALLY DEFERRED,
  CHECK (flavor LIKE engine || '/%')
);

COMMENT ON TABLE cortex.designs IS 'every design people work on here, each the rows of these tables that point at it: never a database, a schema or a table of its own.';
COMMENT ON COLUMN cortex.designs.id IS 'UUIDv7, issued when it is made, never changed: how everything names the design';
COMMENT ON COLUMN cortex.designs.name IS 'as people call it (shop); a rename changes this and nothing else';
COMMENT ON COLUMN cortex.designs.engine IS 'the id of the engine it is designed for, as the registry knows it (mysql)';
COMMENT ON COLUMN cortex.designs.engine_version IS 'one of the engine''s versions; it decides which features the design is offered (8.4)';
COMMENT ON COLUMN cortex.designs.flavor IS 'the managed flavor of its engine it is designed for (mysql/rds, postgresql/alloydb); NULL for the engine''s own server';
COMMENT ON COLUMN cortex.designs.comment IS 'what the design is for, in a sentence or two';
COMMENT ON COLUMN cortex.designs.created_at IS 'when it was made';
