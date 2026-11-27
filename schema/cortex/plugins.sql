-- cortex.plugins: every plugin installed in schema_forge, the cortex among them: its namespace, its schema version, the cortex version it needs, and its two roles, named after its namespace.
CREATE TABLE cortex.plugins (
  id               TEXT NOT NULL PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_]*$'),                                                  -- as the registry knows it (mysql)
  kind             TEXT NOT NULL CHECK (kind IN ('core', 'engine', 'feature')),                                                 -- core: the cortex; engine: a database's plugin; feature: one that adds tables of its own
  namespace        TEXT NOT NULL UNIQUE CHECK (namespace ~ '^[a-z][a-z0-9_]*$'),                                                -- the PostgreSQL schema its tables are in (engine_mysql)
  name             TEXT NOT NULL CHECK (length(name) >= 1),                                                                     -- as people say it (MySQL)
  version          INTEGER NOT NULL CHECK (version >= 1),                                                                       -- its newest schema version installed here
  requires_cortex  INTEGER NOT NULL CHECK (requires_cortex >= 1),                                                               -- the lowest cortex version its tables are written against
  owner            TEXT GENERATED ALWAYS AS (namespace || '_owner') STORED,                                                     -- the role that owns its namespace and runs its migrations, never signing in (engine_mysql_owner)
  account          TEXT GENERATED ALWAYS AS (namespace || '_service') STORED,                                                   -- its service account: the only writer of its namespace, fenced to its engine's designs (engine_mysql_service)
  installed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),                                                                          -- when it was plugged in
  CHECK (kind <> 'engine' OR namespace = 'engine_' || id),
  CHECK (kind <> 'core' OR (id = 'cortex' AND namespace = 'cortex'))
);
