-- engine_mysql's seeds: what it declares to the cortex, loaded by cortex_owner when it is plugged in: the engine, its
-- versions, its flavors (what each refuses and the documentation each fact is from, #140), its kinds of object (the
-- versions that have each, the table that holds each one's details), and its tables as plugs.

INSERT INTO cortex.engines (id, plugin, name) VALUES ('mysql', 'mysql', 'MySQL');

INSERT INTO cortex.engine_versions (id, engine, version, name, position) VALUES
  ('mysql/5.7', 'mysql', '5.7', 'MySQL 5.7', 1),
  ('mysql/8.0', 'mysql', '8.0', 'MySQL 8.0', 2),
  ('mysql/8.4', 'mysql', '8.4', 'MySQL 8.4', 3),
  ('mysql/9.7', 'mysql', '9.7', 'MySQL 9.7', 4);

INSERT INTO cortex.plugin_tables (plugin, name, extends, comment) VALUES
  ('mysql', 'instances', 'namespaces', 'the MySQL server a design is of: its top namespace'),
  ('mysql', 'databases', 'namespaces', 'a database of the server'),
  ('mysql', 'tables', 'objects', 'a table and its table options'),
  ('mysql', 'columns', 'columns', 'what MySQL says of a column beyond the cortex'),
  ('mysql', 'indexes', 'indexes', 'what MySQL says of an index beyond the cortex'),
  ('mysql', 'index_parts', 'index_parts', 'the prefix length of an index part'),
  ('mysql', 'partitionings', 'objects', 'how a table is partitioned'),
  ('mysql', 'partitions', NULL, 'the partitions and subpartitions of a table'),
  ('mysql', 'views', 'objects', 'a view'),
  ('mysql', 'routines', 'objects', 'a stored procedure or function'),
  ('mysql', 'routine_parameters', NULL, 'the parameters of a procedure or function'),
  ('mysql', 'triggers', 'objects', 'a trigger'),
  ('mysql', 'events', 'objects', 'a scheduled event'),
  ('mysql', 'tablespaces', 'objects', 'a general tablespace'),
  ('mysql', 'spatial_reference_systems', 'objects', 'a spatial reference system made on the server'),
  ('mysql', 'libraries', 'objects', 'a JavaScript library'),
  ('mysql', 'accounts', 'objects', 'an account or a role'),
  ('mysql', 'role_grants', NULL, 'a role granted to an account or role'),
  ('mysql', 'privileges', NULL, 'a privilege granted to an account or role'),
  ('mysql', 'servers', 'objects', 'a server a FEDERATED table connects through'),
  ('mysql', 'resource_groups', 'objects', 'a resource group made on the server'),
  ('mysql', 'components', 'objects', 'a component installed on the server'),
  ('mysql', 'loadable_functions', 'objects', 'a loadable function installed on the server'),
  ('mysql', 'compression_dictionaries', 'objects', 'a Percona Server compression dictionary');

INSERT INTO cortex.object_kinds (id, engine, kind, name, has_columns, details, position, since) VALUES
  ('mysql/table', 'mysql', 'table', 'Table', true, 'tables', 1, NULL),
  ('mysql/view', 'mysql', 'view', 'View', true, 'views', 2, NULL),
  ('mysql/procedure', 'mysql', 'procedure', 'Procedure', false, 'routines', 3, NULL),
  ('mysql/function', 'mysql', 'function', 'Function', false, 'routines', 4, NULL),
  ('mysql/trigger', 'mysql', 'trigger', 'Trigger', false, 'triggers', 5, NULL),
  ('mysql/event', 'mysql', 'event', 'Event', false, 'events', 6, NULL),
  ('mysql/library', 'mysql', 'library', 'JavaScript library', false, 'libraries', 7, '9.7'),
  ('mysql/tablespace', 'mysql', 'tablespace', 'Tablespace', false, 'tablespaces', 8, NULL),
  ('mysql/spatial_reference_system', 'mysql', 'spatial_reference_system', 'Spatial reference system', false, 'spatial_reference_systems', 9, '8.0'),
  ('mysql/account', 'mysql', 'account', 'Account', false, 'accounts', 10, NULL),
  ('mysql/role', 'mysql', 'role', 'Role', false, 'accounts', 11, '8.0'),
  ('mysql/server', 'mysql', 'server', 'Server', false, 'servers', 12, NULL),
  ('mysql/resource_group', 'mysql', 'resource_group', 'Resource group', false, 'resource_groups', 13, '8.0'),
  ('mysql/component', 'mysql', 'component', 'Component', false, 'components', 14, '8.0'),
  ('mysql/loadable_function', 'mysql', 'loadable_function', 'Loadable function', false, 'loadable_functions', 15, NULL),
  ('mysql/compression_dictionary', 'mysql', 'compression_dictionary', 'Compression dictionary', false, 'compression_dictionaries', 16, NULL);

-- the flavors: every one but Percona refuses its compression dictionaries; each fact names its page
INSERT INTO cortex.engine_flavors (id, engine, flavor, name, refuses, options, sources) VALUES
  ('mysql/mysql', 'mysql', 'mysql', 'MySQL',
   '{"kinds": ["compression_dictionary"]}', '{}',
   '["https://dev.mysql.com/doc/"]'),
  ('mysql/percona', 'mysql', 'percona', 'Percona Server for MySQL',
   '{"versions": ["9.7"]}', '{}',
   '["https://docs.percona.com/percona-server/8.4/", "https://docs.percona.com/percona-server/8.0/compressed-columns.html"]'),
  ('mysql/rds', 'mysql', 'rds', 'Amazon RDS for MySQL',
   '{"kinds": ["compression_dictionary"], "database_names": ["InnoDB"], "table_options": ["compression"]}', '{}',
   '["https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.KnownIssuesAndLimitations.html"]'),
  ('mysql/cloudsql', 'mysql', 'cloudsql', 'Cloud SQL for MySQL',
   '{"versions": ["9.7"], "kinds": ["compression_dictionary", "loadable_function"], "engines": ["MyISAM", "MRG_MYISAM", "MEMORY", "FEDERATED", "ARCHIVE", "CSV", "BLACKHOLE"], "privileges": ["SUPER", "FILE", "TRANSACTION_GTID_TAG", "TELEMETRY_LOG_ADMIN"]}', '{}',
   '["https://docs.cloud.google.com/sql/docs/mysql/features"]'),
  ('mysql/aurora', 'mysql', 'aurora', 'Amazon Aurora MySQL',
   '{"versions": ["5.7", "8.4", "9.7"], "kinds": ["compression_dictionary", "resource_group"], "engines": ["MyISAM", "MRG_MYISAM", "MEMORY", "FEDERATED", "ARCHIVE", "CSV", "BLACKHOLE"]}', '{}',
   '["https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Compare-80-v3.html", "https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Migrating.ExtMySQL.Prechecks.html"]');
