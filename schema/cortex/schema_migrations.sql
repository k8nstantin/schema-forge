-- cortex.schema_migrations: every schema version of every plugin applied to schema_forge, the cortex's among them.
CREATE TABLE cortex.schema_migrations (
  plugin      TEXT NOT NULL REFERENCES cortex.plugins (id) ON DELETE CASCADE,  -- the plugin
  version     INTEGER NOT NULL CHECK (version >= 1),                          -- the version applied
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),                             -- when
  PRIMARY KEY (plugin, version)
);
