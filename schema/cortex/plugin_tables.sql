-- cortex.plugin_tables: every table a plugin brings, and the cortex table each extends: how the canvas, the agent and the log find an object's engine details.
CREATE TABLE cortex.plugin_tables (
  plugin   TEXT NOT NULL REFERENCES cortex.plugins (id) ON DELETE CASCADE,                                           -- the plugin that brings it
  name     TEXT NOT NULL CHECK (name ~ '^[a-z][a-z0-9_]*$'),                                                         -- its name in the plugin's namespace (tables)
  extends  TEXT CHECK (extends IN ('namespaces', 'objects', 'columns', 'indexes', 'constraints')),                   -- the cortex table whose rows it extends, one row each with the same id; NULL for a part of its own (a routine's parameters)
  comment  TEXT NOT NULL CHECK (length(comment) >= 1),                                                               -- what it holds
  PRIMARY KEY (plugin, name)
);
