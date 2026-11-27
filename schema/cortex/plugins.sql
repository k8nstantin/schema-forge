-- cortex.plugins: every plugin installed in schema_forge, the cortex among them: its namespace, its schema version and the cortex version it needs.
CREATE TABLE cortex.plugins (
  id               TEXT NOT NULL PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_]*$'),                      -- as the registry knows it (mysql)
  kind             TEXT NOT NULL CHECK (kind IN ('core', 'engine', 'feature')),                     -- core: the cortex; engine: a database's plugin; feature: one that adds tables of its own
  namespace        TEXT NOT NULL UNIQUE CHECK (namespace ~ '^[a-z][a-z0-9_]*$'),                    -- the PostgreSQL schema its tables are in (engine_mysql)
  name             TEXT NOT NULL CHECK (length(name) >= 1),                                         -- as people say it (MySQL)
  version          INTEGER NOT NULL CHECK (version >= 1),                                           -- its newest schema version installed here
  requires_cortex  INTEGER NOT NULL CHECK (requires_cortex >= 1),                                   -- the lowest cortex version its tables are written against
  account          TEXT UNIQUE CHECK (account ~ '^sf_[a-z][a-z0-9_]*$'),                            -- its own service account: writes only its namespace and the cortex rows of its engine's designs (sf_mysql); NULL for the cortex
  installed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),                                              -- when it was plugged in
  CHECK (kind <> 'engine' OR namespace = 'engine_' || id),
  CHECK (kind <> 'core' OR (id = 'cortex' AND namespace = 'cortex' AND account IS NULL)),
  CHECK (kind = 'core' OR account = 'sf_' || id)
);
