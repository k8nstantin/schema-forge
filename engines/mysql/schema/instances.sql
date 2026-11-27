-- engine_mysql.instances: the MySQL server a design is of: the top namespace, which holds the server's own objects (accounts, roles, tablespaces, spatial reference systems, servers, resource groups, components, loadable functions, libraries' server, dictionaries) and every database under it.
CREATE TABLE engine_mysql.instances (
  id                      UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex namespace
  design                  UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  version                 TEXT NOT NULL CHECK (length(version) >= 1),                                                      -- the server's full version as it gives it (8.0.46, 8.0.46-37 for Percona)
  character_set           TEXT NOT NULL,                                                                                   -- the server's default character set (character_set_server)
  "collation"             TEXT NOT NULL,                                                                                   -- the server's default collation (collation_server)
  lower_case_table_names  INTEGER NOT NULL CHECK (lower_case_table_names IN (0, 1, 2)),                                    -- how the server stores and compares names, fixed when it was made
  sql_mode                TEXT NOT NULL,                                                                                   -- the server's default SQL mode
  flavor_options          JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(flavor_options) = 'object'),                     -- what only its flavor says of the server, by the keys its flavor declares
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
