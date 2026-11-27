-- cortex.engine_flavors: the flavors of each engine a design may be made for: the engine itself, and each fork or managed service that is a subset of it (Percona Server, Cloud SQL, RDS, Aurora, AlloyDB); what each refuses is its plugin's.
CREATE TABLE cortex.engine_flavors (
  id      TEXT NOT NULL PRIMARY KEY,                                        -- <engine>/<flavor>: mysql/aurora
  engine  TEXT NOT NULL REFERENCES cortex.engines (id) ON DELETE CASCADE,   -- the engine it is a flavor of
  flavor  TEXT NOT NULL CHECK (flavor ~ '^[a-z][a-z0-9_]*$'),               -- as the plugin names it; the engine's own is named as the engine (mysql)
  name    TEXT NOT NULL CHECK (length(name) >= 1),                          -- as people say it (Amazon Aurora MySQL)
  UNIQUE (engine, flavor),
  CHECK (id = engine || '/' || flavor)
);
