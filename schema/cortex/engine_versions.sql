-- cortex.engine_versions: the versions of each engine's database a design may be made for, oldest first.
CREATE TABLE cortex.engine_versions (
  id        TEXT NOT NULL PRIMARY KEY,                                         -- <engine>/<version>: mysql/8.4
  engine    TEXT NOT NULL REFERENCES cortex.engines (id) ON DELETE CASCADE,    -- the engine
  version   TEXT NOT NULL CHECK (version ~ '^[0-9A-Za-z][0-9A-Za-z.\-]*$'),    -- as the engine names it (5.7, 18)
  name      TEXT NOT NULL CHECK (length(name) >= 1),                           -- as people say it (MySQL 8.4)
  position  NUMERIC NOT NULL CHECK (position > 0),                             -- its place among the engine's versions, oldest first: versions compare by it
  UNIQUE (engine, version),
  UNIQUE (engine, position),
  CHECK (id = engine || '/' || version)
);
