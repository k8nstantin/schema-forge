-- cortex.designs: every design people work on: one engine, version and flavor; everything of it is rows of these tables and its plugin's that point at it, never a database, a schema or a table of its own.
CREATE TABLE cortex.designs (
  id              UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),  -- a UUIDv7 made with its row, never changed: how everything names the design
  name            TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 100),                      -- as people call it (shop); a rename changes this and nothing else
  engine          TEXT NOT NULL REFERENCES cortex.engines (id),                                     -- the engine it is made for (mysql)
  engine_version  TEXT NOT NULL,                                                                    -- the engine's version it is made for (8.4)
  flavor          TEXT NOT NULL,                                                                    -- the engine's flavor it is made for (mysql, percona, aurora)
  comment         TEXT,                                                                             -- what it is for, in a sentence or two
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),                                               -- when it was made
  UNIQUE (id, engine),
  FOREIGN KEY (engine, engine_version) REFERENCES cortex.engine_versions (engine, version),
  FOREIGN KEY (engine, flavor) REFERENCES cortex.engine_flavors (engine, flavor)
);
