-- cortex.engines: the databases designs are made for, each brought by its plugin.
CREATE TABLE cortex.engines (
  id      TEXT NOT NULL PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9_]*$'),     -- as the registry knows it (mysql)
  plugin  TEXT NOT NULL REFERENCES cortex.plugins (id) ON DELETE CASCADE,  -- the plugin that brings it
  name    TEXT NOT NULL CHECK (length(name) >= 1)                          -- as people say it (MySQL)
);
