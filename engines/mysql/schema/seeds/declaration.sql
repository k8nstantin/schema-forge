-- declaration: what MySQL is, as data: its versions, the features each has or lacks, its kinds of object, and every option it adds
-- to a part of the model (decision declared-options). The engine's one source: its code is made from these rows. Owner: mysql.
-- Inserted only where the id is missing: a row the app or a person changed is never overwritten by a later version's seed.

INSERT INTO cortex.engine_versions (id, engine, version, name, position, support_ends) VALUES
  ('mysql/5.7', 'mysql', '5.7', 'MySQL 5.7', 1, '2023-10-31'),
  ('mysql/8.0', 'mysql', '8.0', 'MySQL 8.0', 2, '2026-04-30'),
  ('mysql/8.4', 'mysql', '8.4', 'MySQL 8.4', 3, NULL),
  ('mysql/9.7', 'mysql', '9.7', 'MySQL 9.7', 4, NULL),
  ('mysql/26.7', 'mysql', '26.7', 'MySQL 26.7', 5, NULL),
  ('mysql/26.10', 'mysql', '26.10', 'MySQL 26.10', 6, NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO cortex.engine_features (id, engine, feature, what, since, "until", detail) VALUES
  ('mysql/auto_increment_float', 'mysql', 'auto_increment_float', 'AUTO_INCREMENT on a FLOAT or DOUBLE column', NULL, 'mysql/8.0', 'removed in 8.4'),
  ('mysql/nonstandard_foreign_key', 'mysql', 'nonstandard_foreign_key', 'a foreign key to columns that are not a primary key or a unique', NULL, 'mysql/8.0', 'refused by default from 8.4'),
  ('mysql/partition_key_prefix', 'mysql', 'partition_key_prefix', 'a column prefix in a partitioning key', NULL, 'mysql/8.0', 'removed in 8.4'),
  ('mysql/vector', 'mysql', 'vector', 'the VECTOR type', 'mysql/9.7', NULL, 'from 9.0'),
  ('mysql/inline_references', 'mysql', 'inline_references', 'a foreign key written on its column (REFERENCES), enforced', 'mysql/9.7', NULL, 'from 9.0'),
  ('mysql/libraries', 'mysql', 'libraries', 'JavaScript and WASM libraries and stored programs', 'mysql/9.7', NULL, '9.0, 9.2')
ON CONFLICT (id) DO NOTHING;


-- the managed flavors of the engine (decision schema-per-engine), and what each lacks, each fact with the page it was read on
INSERT INTO cortex.engine_flavors (id, engine, flavor, name, position, about) VALUES
  ('mysql/rds', 'mysql', 'rds', 'Amazon RDS for MySQL', 1, 'MySQL run by Amazon RDS: the community server''s versions, without some engines and plugins'),
  ('mysql/aurora', 'mysql', 'aurora', 'Amazon Aurora MySQL', 2, 'Amazon''s MySQL-compatible engine on its own storage: version 2 follows MySQL 5.7, version 3 MySQL 8.0'),
  ('mysql/cloudsql', 'mysql', 'cloudsql', 'Cloud SQL for MySQL', 3, 'MySQL run by Google Cloud SQL: InnoDB alone, no plugins or server-side files')
ON CONFLICT (id) DO NOTHING;

INSERT INTO cortex.object_kinds (id, engine, kind, name, position, scope, since) VALUES
  ('mysql/table', 'mysql', 'table', 'Table', 1, 'namespace', NULL),
  ('mysql/view', 'mysql', 'view', 'View', 2, 'namespace', NULL),
  ('mysql/procedure', 'mysql', 'procedure', 'Procedure', 3, 'namespace', NULL),
  ('mysql/function', 'mysql', 'function', 'Function', 4, 'namespace', NULL),
  ('mysql/loadable_function', 'mysql', 'loadable_function', 'Loadable function', 5, 'server', NULL),
  ('mysql/library', 'mysql', 'library', 'Library', 6, 'namespace', 'mysql/9.7'),
  ('mysql/trigger', 'mysql', 'trigger', 'Trigger', 7, 'namespace', NULL),
  ('mysql/event', 'mysql', 'event', 'Event', 8, 'namespace', NULL),
  ('mysql/tablespace', 'mysql', 'tablespace', 'Tablespace', 9, 'server', NULL),
  ('mysql/spatial_reference_system', 'mysql', 'spatial_reference_system', 'Spatial reference system', 10, 'server', 'mysql/8.0'),
  ('mysql/account', 'mysql', 'account', 'Account', 11, 'server', NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO cortex.option_declarations (id, engine, part, name, value_type, nullable, choices, since, about) VALUES
  ('mysql/objects/language', 'mysql', 'objects', 'language', 'string', false, NULL, 'mysql/9.7', 'a library''s language, as SHOW CREATE LIBRARY writes it (JAVASCRIPT)'),
  ('mysql/dependencies/alias', 'mysql', 'dependencies', 'alias', 'string', true, NULL, 'mysql/9.7', 'the name a routine''s code calls a library it uses by (USING (lib AS util)); NULL for the library''s own name'),
  ('mysql/objects/role', 'mysql', 'objects', 'role', 'boolean', false, NULL, 'mysql/8.0', 'true for an account made as a role (CREATE ROLE): locked, with no password'),
  ('mysql/memberships/default_role', 'mysql', 'memberships', 'default_role', 'boolean', false, NULL, 'mysql/8.0', 'true when the role is one of the member''s default roles, active as it signs in'),
  ('mysql/objects/autoextend_size', 'mysql', 'objects', 'autoextend_size', 'number', true, NULL, 'mysql/8.0', 'a tablespace''s AUTOEXTEND_SIZE in bytes, where written (8.0.23 and later); NULL for none'),
  ('mysql/objects/srs_id', 'mysql', 'objects', 'srs_id', 'number', false, NULL, 'mysql/8.0', 'a spatial reference system''s number, the SRID a column names it by (outside the ranges MySQL reserves for its own)'),
  ('mysql/objects/organization', 'mysql', 'objects', 'organization', 'string', true, NULL, 'mysql/8.0', 'the organization that defines a spatial reference system; NULL for none'),
  ('mysql/objects/organization_coordsys_id', 'mysql', 'objects', 'organization_coordsys_id', 'number', true, NULL, 'mysql/8.0', 'the number the organization gives it (IDENTIFIED BY); NULL with no organization'),
  ('mysql/objects/definition', 'mysql', 'objects', 'definition', 'string', false, NULL, 'mysql/8.0', 'a spatial reference system''s definition, in WKT, exactly as the server holds it')
ON CONFLICT (id) DO NOTHING;

INSERT INTO cortex.option_declarations (id, engine, part, name, value_type, nullable, choices, about) VALUES
  ('mysql/columns/on_update', 'mysql', 'columns', 'on_update', 'string', true, NULL, 'what it becomes whenever its row changes (CURRENT_TIMESTAMP); NULL for none'),
  ('mysql/columns/srid', 'mysql', 'columns', 'srid', 'number', true, NULL, 'the spatial reference system of its shapes; NULL for none'),
  ('mysql/columns/invisible', 'mysql', 'columns', 'invisible', 'boolean', false, NULL, 'true when SELECT * leaves it out (8.0.23 and later)'),
  ('mysql/namespaces/collation', 'mysql', 'namespaces', 'collation', 'string', false, NULL, 'its default collation; its character set is the collation''s'),
  ('mysql/namespaces/encryption', 'mysql', 'namespaces', 'encryption', 'boolean', true, NULL, 'its default encryption (8.0 and later); NULL before'),
  ('mysql/objects/body', 'mysql', 'objects', 'body', 'string', false, NULL, 'an event''s statements, or a library''s code after AS ($$ ... $$), exactly as SHOW CREATE holds them'),
  ('mysql/objects/interval_value', 'mysql', 'objects', 'interval_value', 'string', true, NULL, 'EVERY''s value as the server gives it (5, ''1:30''); NULL for a one-time event'),
  ('mysql/objects/interval_field', 'mysql', 'objects', 'interval_field', 'string', true, NULL, 'EVERY''s unit (MINUTE, DAY, HOUR_MINUTE); NULL for a one-time event'),
  ('mysql/objects/execute_at', 'mysql', 'objects', 'execute_at', 'string', true, NULL, 'a one-time event''s moment, as the server writes it (2030-01-01 00:00:00), in its time zone; NULL for a recurring one'),
  ('mysql/objects/starts', 'mysql', 'objects', 'starts', 'string', true, NULL, 'when a recurring event starts, as the server writes it; NULL when not written'),
  ('mysql/objects/ends', 'mysql', 'objects', 'ends', 'string', true, NULL, 'when a recurring event ends, as the server writes it; NULL when not written'),
  ('mysql/objects/status', 'mysql', 'objects', 'status', 'string', false, '["ENABLE", "DISABLE", "DISABLE ON SLAVE", "DISABLE ON REPLICA"]', 'whether it runs'),
  ('mysql/objects/preserve', 'mysql', 'objects', 'preserve', 'boolean', false, NULL, 'true when it is kept once its schedule is over'),
  ('mysql/index_parts/length', 'mysql', 'index_parts', 'length', 'number', false, NULL, 'how many characters or bytes of the column it indexes'),
  ('mysql/indexes/invisible', 'mysql', 'indexes', 'invisible', 'boolean', false, NULL, 'true when the optimizer ignores it (8.0 and later)'),
  ('mysql/indexes/parser', 'mysql', 'indexes', 'parser', 'string', true, NULL, 'the full-text parser it uses (ngram); NULL for none'),
  ('mysql/objects/sql_mode', 'mysql', 'objects', 'sql_mode', 'string', true, NULL, 'the SQL mode it was made under, from SHOW CREATE (5.7''s ROUTINES misnames one mode); NULL for a view'),
  ('mysql/objects/character_set_client', 'mysql', 'objects', 'character_set_client', 'string', false, NULL, 'the character set its text was written in: it is sent back in that character set'),
  ('mysql/objects/collation_connection', 'mysql', 'objects', 'collation_connection', 'string', false, NULL, 'the collation it was made under'),
  ('mysql/objects/database_collation', 'mysql', 'objects', 'database_collation', 'string', true, NULL, 'its database''s collation when it was made; NULL for a view'),
  ('mysql/objects/time_zone', 'mysql', 'objects', 'time_zone', 'string', true, NULL, 'the time zone an event''s schedule is read in; NULL for any other kind'),
  ('mysql/routines/parameter_text', 'mysql', 'routines', 'parameter_text', 'string', false, NULL, 'its parameter list exactly as written: real code formats it by hand, so it is not rebuilt from the parameters'),
  ('mysql/routines/data_access', 'mysql', 'routines', 'data_access', 'string', false, '["CONTAINS SQL", "NO SQL", "READS SQL DATA", "MODIFIES SQL DATA"]', 'what it does with data'),
  ('mysql/routines/returns_charset', 'mysql', 'routines', 'returns_charset', 'string', true, NULL, 'a function''s result character set (RETURNS varchar(10) CHARSET latin1); NULL for none'),
  ('mysql/routines/parameter_collation', 'mysql', 'routines', 'parameter_collation', 'string', true, NULL, 'the collation its parameters without a character set took: the current database''s when it was made, not always its own'),
  ('mysql/partitionings/strategy', 'mysql', 'partitionings', 'strategy', 'string', false, NULL, 'how a partition is split again (HASH, KEY, LINEAR HASH)'),
  ('mysql/partitionings/expression', 'mysql', 'partitionings', 'expression', 'string', false, NULL, 'what it is split by, as the server writes it'),
  ('mysql/objects/engine', 'mysql', 'objects', 'engine', 'string', false, NULL, 'its storage engine, as SHOW CREATE writes it (InnoDB, MyISAM, MRG_MyISAM)'),
  ('mysql/objects/collation', 'mysql', 'objects', 'collation', 'string', false, NULL, 'its default collation; its character set is the collation''s'),
  ('mysql/objects/auto_increment', 'mysql', 'objects', 'auto_increment', 'number', true, NULL, 'the next number its AUTO_INCREMENT column gives, from SHOW CREATE (TABLES caches it on 8.0 and later); NULL when not written'),
  ('mysql/objects/row_format', 'mysql', 'objects', 'row_format', 'string', true, NULL, 'ROW_FORMAT, where written'),
  ('mysql/objects/avg_row_length', 'mysql', 'objects', 'avg_row_length', 'number', true, NULL, 'AVG_ROW_LENGTH, where written'),
  ('mysql/objects/min_rows', 'mysql', 'objects', 'min_rows', 'number', true, NULL, 'MIN_ROWS, where written'),
  ('mysql/objects/max_rows', 'mysql', 'objects', 'max_rows', 'number', true, NULL, 'MAX_ROWS, where written'),
  ('mysql/objects/pack_keys', 'mysql', 'objects', 'pack_keys', 'string', true, NULL, 'PACK_KEYS, where written'),
  ('mysql/objects/checksum', 'mysql', 'objects', 'checksum', 'string', true, NULL, 'CHECKSUM, where written'),
  ('mysql/objects/delay_key_write', 'mysql', 'objects', 'delay_key_write', 'string', true, NULL, 'DELAY_KEY_WRITE, where written'),
  ('mysql/objects/key_block_size', 'mysql', 'objects', 'key_block_size', 'number', true, NULL, 'KEY_BLOCK_SIZE, where written'),
  ('mysql/objects/stats_persistent', 'mysql', 'objects', 'stats_persistent', 'string', true, NULL, 'STATS_PERSISTENT, where written'),
  ('mysql/objects/stats_auto_recalc', 'mysql', 'objects', 'stats_auto_recalc', 'string', true, NULL, 'STATS_AUTO_RECALC, where written'),
  ('mysql/objects/stats_sample_pages', 'mysql', 'objects', 'stats_sample_pages', 'string', true, NULL, 'STATS_SAMPLE_PAGES, where written'),
  ('mysql/objects/compression', 'mysql', 'objects', 'compression', 'string', true, NULL, 'COMPRESSION, where written'),
  ('mysql/objects/encryption', 'mysql', 'objects', 'encryption', 'string', true, NULL, 'ENCRYPTION, where written'),
  ('mysql/objects/tablespace', 'mysql', 'objects', 'tablespace', 'string', true, NULL, 'the tablespace a table is stored in, by name, where it is one the design does not hold (innodb_system); one it holds is a dependency'),
  ('mysql/objects/auth_plugin', 'mysql', 'objects', 'auth_plugin', 'string', false, NULL, 'an account''s authentication plugin (caching_sha2_password, mysql_native_password); never its password'),
  ('mysql/objects/locked', 'mysql', 'objects', 'locked', 'boolean', false, NULL, 'true when an account may not sign in (ACCOUNT LOCK)'),
  ('mysql/objects/require', 'mysql', 'objects', 'require', 'string', false, '["NONE", "SSL", "X509", "SPECIFIED"]', 'the TLS an account must sign in with (REQUIRE)'),
  ('mysql/objects/max_queries_per_hour', 'mysql', 'objects', 'max_queries_per_hour', 'number', false, NULL, 'an account''s queries an hour; 0 for no limit'),
  ('mysql/objects/max_updates_per_hour', 'mysql', 'objects', 'max_updates_per_hour', 'number', false, NULL, 'an account''s updates an hour; 0 for no limit'),
  ('mysql/objects/max_connections_per_hour', 'mysql', 'objects', 'max_connections_per_hour', 'number', false, NULL, 'an account''s connections an hour; 0 for no limit'),
  ('mysql/objects/max_user_connections', 'mysql', 'objects', 'max_user_connections', 'number', false, NULL, 'an account''s connections at once; 0 for the server''s limit'),
  ('mysql/objects/datafile', 'mysql', 'objects', 'datafile', 'string', false, NULL, 'a tablespace''s data file, as the server gives it (./ts_shared.ibd)'),
  ('mysql/objects/file_block_size', 'mysql', 'objects', 'file_block_size', 'number', true, NULL, 'a compressed tablespace''s FILE_BLOCK_SIZE in bytes; NULL for an uncompressed one'),
  ('mysql/objects/soname', 'mysql', 'objects', 'soname', 'string', false, NULL, 'the shared library a loadable function is in (SONAME), as registered'),
  ('mysql/objects/returns', 'mysql', 'objects', 'returns', 'string', false, '["STRING", "INTEGER", "REAL", "DECIMAL"]', 'what a loadable function returns'),
  ('mysql/objects/aggregate', 'mysql', 'objects', 'aggregate', 'boolean', false, NULL, 'true for an aggregate loadable function (CREATE AGGREGATE FUNCTION)'),
  ('mysql/objects/insert_method', 'mysql', 'objects', 'insert_method', 'string', true, NULL, 'a MERGE table''s INSERT_METHOD; its tables are dependencies, in order'),
  ('mysql/views/algorithm', 'mysql', 'views', 'algorithm', 'string', false, '["UNDEFINED", "MERGE", "TEMPTABLE"]', 'how its query is run: SHOW CREATE VIEW alone holds it'),
  ('mysql/views/security', 'mysql', 'views', 'security', 'string', false, '["DEFINER", "INVOKER"]', 'whose rights it runs with')
ON CONFLICT (id) DO NOTHING;

-- what each flavor lacks
INSERT INTO cortex.flavor_limits (id, flavor, what, kind, option, value, name, since, "until", severity, about, source) VALUES
  ('mysql/cloudsql/kind/loadable_function', 'mysql/cloudsql', 'kind', 'mysql/loadable_function', NULL, NULL, NULL, NULL, NULL, 'refused', 'CREATE FUNCTION ... SONAME is not supported: no library can be loaded', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/cloudsql/value/objects.engine.MyISAM', 'mysql/cloudsql', 'value', NULL, 'mysql/objects/engine', '"MyISAM"', NULL, NULL, NULL, 'refused', 'InnoDB is the only storage engine it supports: a MyISAM table must become InnoDB', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/cloudsql/value/objects.engine.MEMORY', 'mysql/cloudsql', 'value', NULL, 'mysql/objects/engine', '"MEMORY"', NULL, NULL, NULL, 'refused', 'InnoDB is the only storage engine it supports: a MEMORY table must become InnoDB', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/cloudsql/value/objects.engine.FEDERATED', 'mysql/cloudsql', 'value', NULL, 'mysql/objects/engine', '"FEDERATED"', NULL, NULL, NULL, 'refused', 'InnoDB is the only storage engine it supports: a FEDERATED table must become InnoDB', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/cloudsql/value/objects.engine.MRG_MyISAM', 'mysql/cloudsql', 'value', NULL, 'mysql/objects/engine', '"MRG_MyISAM"', NULL, NULL, NULL, 'refused', 'InnoDB is the only storage engine it supports: a MRG_MyISAM table must become InnoDB', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/cloudsql/value/objects.engine.ARCHIVE', 'mysql/cloudsql', 'value', NULL, 'mysql/objects/engine', '"ARCHIVE"', NULL, NULL, NULL, 'refused', 'InnoDB is the only storage engine it supports: a ARCHIVE table must become InnoDB', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/cloudsql/value/objects.engine.CSV', 'mysql/cloudsql', 'value', NULL, 'mysql/objects/engine', '"CSV"', NULL, NULL, NULL, 'refused', 'InnoDB is the only storage engine it supports: a CSV table must become InnoDB', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/cloudsql/value/objects.engine.BLACKHOLE', 'mysql/cloudsql', 'value', NULL, 'mysql/objects/engine', '"BLACKHOLE"', NULL, NULL, NULL, 'refused', 'InnoDB is the only storage engine it supports: a BLACKHOLE table must become InnoDB', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/cloudsql/value/objects.encryption.Y', 'mysql/cloudsql', 'value', NULL, 'mysql/objects/encryption', '"Y"', NULL, NULL, NULL, 'refused', 'InnoDB data-at-rest encryption is not supported', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/cloudsql/value/namespaces.encryption.true', 'mysql/cloudsql', 'value', NULL, 'mysql/namespaces/encryption', 'true', NULL, NULL, NULL, 'refused', 'InnoDB data-at-rest encryption is not supported', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/cloudsql/function/LOAD_FILE', 'mysql/cloudsql', 'function', NULL, NULL, NULL, 'LOAD_FILE', NULL, NULL, 'refused', 'LOAD_FILE() is not supported: a routine that calls it fails when run', 'https://docs.cloud.google.com/sql/docs/mysql/features'),
  ('mysql/rds/value/objects.engine.FEDERATED', 'mysql/rds', 'value', NULL, 'mysql/objects/engine', '"FEDERATED"', NULL, NULL, NULL, 'refused', 'the Federated storage engine is not supported', 'https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.FeatureSupport.html'),
  ('mysql/rds/value/objects.engine.MyISAM', 'mysql/rds', 'value', NULL, 'mysql/objects/engine', '"MyISAM"', NULL, NULL, NULL, 'warned', 'MyISAM tables are taken, but do not recover reliably: point-in-time and snapshot restores may lose or corrupt them', 'https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.FeatureSupport.html'),
  ('mysql/rds/value/objects.encryption.Y', 'mysql/rds', 'value', NULL, 'mysql/objects/encryption', '"Y"', NULL, NULL, NULL, 'refused', 'InnoDB tablespace encryption is not supported', 'https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.FeatureSupport.html'),
  ('mysql/rds/value/namespaces.encryption.true', 'mysql/rds', 'value', NULL, 'mysql/namespaces/encryption', 'true', NULL, NULL, NULL, 'refused', 'InnoDB tablespace encryption is not supported', 'https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.FeatureSupport.html'),
  ('mysql/rds/function/MD5', 'mysql/rds', 'function', NULL, NULL, NULL, 'MD5', 'mysql/9.7', NULL, 'refused', 'MD5() is not available on RDS for MySQL 9.7; the upgrade precheck blocks a routine, view, trigger, event, default or index that uses it', 'https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.FeatureSupport.html'),
  ('mysql/rds/function/SHA1', 'mysql/rds', 'function', NULL, NULL, NULL, 'SHA1', 'mysql/9.7', NULL, 'refused', 'SHA1() is not available on RDS for MySQL 9.7; the upgrade precheck blocks a routine, view, trigger, event, default or index that uses it', 'https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.FeatureSupport.html'),
  ('mysql/rds/function/SHA', 'mysql/rds', 'function', NULL, NULL, NULL, 'SHA', 'mysql/9.7', NULL, 'refused', 'SHA() is not available on RDS for MySQL 9.7; the upgrade precheck blocks a routine, view, trigger, event, default or index that uses it', 'https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.FeatureSupport.html'),
  ('mysql/aurora/kind/tablespace', 'mysql/aurora', 'kind', 'mysql/tablespace', NULL, NULL, NULL, NULL, 'mysql/5.7', 'refused', 'Aurora MySQL version 2 (MySQL 5.7) does not support CREATE TABLESPACE', 'https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.CompareMySQL57.html')
ON CONFLICT (id) DO NOTHING;

-- what each reference may point at (decision reference-kinds), checked by cortex.check_references
INSERT INTO cortex.reference_kinds (id, engine, part, field, condition_field, condition_value, kinds, about) VALUES
  ('mysql/cortex.columns.object', 'mysql', 'cortex.columns', 'object', NULL, NULL, '["table", "view"]', 'the table or view a column is of'),
  ('mysql/cortex.indexes.object', 'mysql', 'cortex.indexes', 'object', NULL, NULL, '["table"]', 'the table an index is on'),
  ('mysql/cortex.constraints.object', 'mysql', 'cortex.constraints', 'object', NULL, NULL, '["table"]', 'the table a key or check is on'),
  ('mysql/cortex.constraints.to_object', 'mysql', 'cortex.constraints', 'to_object', NULL, NULL, '["table"]', 'the table a foreign key refers to'),
  ('mysql/cortex.partitionings.id', 'mysql', 'cortex.partitionings', 'id', NULL, NULL, '["table"]', 'the table partitioned'),
  ('mysql/cortex.partitions.table_object', 'mysql', 'cortex.partitions', 'table_object', NULL, NULL, '["table"]', 'a partition''s own table'),
  ('mysql/cortex.views.id', 'mysql', 'cortex.views', 'id', NULL, NULL, '["view"]', 'the view whose query this is'),
  ('mysql/cortex.routines.id', 'mysql', 'cortex.routines', 'id', NULL, NULL, '["procedure", "function"]', 'the routine whose body this is'),
  ('mysql/cortex.routine_parameters.routine', 'mysql', 'cortex.routine_parameters', 'routine', NULL, NULL, '["procedure", "function"]', 'the routine a parameter is of'),
  ('mysql/cortex.triggers.id', 'mysql', 'cortex.triggers', 'id', NULL, NULL, '["trigger"]', 'the trigger whose timing and body this is'),
  ('mysql/cortex.objects.parent/kind=trigger', 'mysql', 'cortex.objects', 'parent', 'kind', 'trigger', '["table"]', 'the table a trigger fires on'),
  ('mysql/cortex.objects.owner', 'mysql', 'cortex.objects', 'owner', NULL, NULL, '["account"]', 'the account an object belongs to and runs as (DEFINER)'),
  ('mysql/cortex.privileges.grantee', 'mysql', 'cortex.privileges', 'grantee', NULL, NULL, '["account"]', 'the account a privilege is given to'),
  ('mysql/cortex.privileges.object', 'mysql', 'cortex.privileges', 'object', NULL, NULL, '["table", "view", "procedure", "function"]', 'what a privilege is on'),
  ('mysql/cortex.memberships.role', 'mysql', 'cortex.memberships', 'role', NULL, NULL, '["account"]', 'the role granted, an account made as a role'),
  ('mysql/cortex.memberships.member', 'mysql', 'cortex.memberships', 'member', NULL, NULL, '["account"]', 'the account a role is granted to'),
  ('mysql/cortex.dependencies.uses', 'mysql', 'cortex.dependencies', 'uses', NULL, NULL, '["table", "view", "tablespace", "library", "procedure", "function"]', 'what an object uses')
ON CONFLICT (id) DO NOTHING;

-- the privileges the engine grants, where, and in which versions (decision reference-kinds)
INSERT INTO cortex.privilege_declarations (id, engine, privilege, levels, pattern, since, "until", about) VALUES
  ('mysql/CREATE USER', 'mysql', 'CREATE USER', '["server"]', false, NULL, NULL, 'what CREATE USER lets its grantee do, as MySQL defines it'),
  ('mysql/CREATE TABLESPACE', 'mysql', 'CREATE TABLESPACE', '["server"]', false, NULL, NULL, 'what CREATE TABLESPACE lets its grantee do, as MySQL defines it'),
  ('mysql/FILE', 'mysql', 'FILE', '["server"]', false, NULL, NULL, 'what FILE lets its grantee do, as MySQL defines it'),
  ('mysql/PROCESS', 'mysql', 'PROCESS', '["server"]', false, NULL, NULL, 'what PROCESS lets its grantee do, as MySQL defines it'),
  ('mysql/RELOAD', 'mysql', 'RELOAD', '["server"]', false, NULL, NULL, 'what RELOAD lets its grantee do, as MySQL defines it'),
  ('mysql/REPLICATION CLIENT', 'mysql', 'REPLICATION CLIENT', '["server"]', false, NULL, NULL, 'what REPLICATION CLIENT lets its grantee do, as MySQL defines it'),
  ('mysql/REPLICATION SLAVE', 'mysql', 'REPLICATION SLAVE', '["server"]', false, NULL, NULL, 'what REPLICATION SLAVE lets its grantee do, as MySQL defines it'),
  ('mysql/SHOW DATABASES', 'mysql', 'SHOW DATABASES', '["server"]', false, NULL, NULL, 'what SHOW DATABASES lets its grantee do, as MySQL defines it'),
  ('mysql/SHUTDOWN', 'mysql', 'SHUTDOWN', '["server"]', false, NULL, NULL, 'what SHUTDOWN lets its grantee do, as MySQL defines it'),
  ('mysql/SUPER', 'mysql', 'SUPER', '["server"]', false, NULL, NULL, 'what SUPER lets its grantee do, as MySQL defines it'),
  ('mysql/CREATE ROLE', 'mysql', 'CREATE ROLE', '["server"]', false, 'mysql/8.0', NULL, 'what CREATE ROLE lets its grantee do, as MySQL defines it'),
  ('mysql/DROP ROLE', 'mysql', 'DROP ROLE', '["server"]', false, 'mysql/8.0', NULL, 'what DROP ROLE lets its grantee do, as MySQL defines it'),
  ('mysql/CREATE ROUTINE', 'mysql', 'CREATE ROUTINE', '["server", "namespace"]', false, NULL, NULL, 'what CREATE ROUTINE lets its grantee do, as MySQL defines it'),
  ('mysql/CREATE TEMPORARY TABLES', 'mysql', 'CREATE TEMPORARY TABLES', '["server", "namespace"]', false, NULL, NULL, 'what CREATE TEMPORARY TABLES lets its grantee do, as MySQL defines it'),
  ('mysql/EVENT', 'mysql', 'EVENT', '["server", "namespace"]', false, NULL, NULL, 'what EVENT lets its grantee do, as MySQL defines it'),
  ('mysql/LOCK TABLES', 'mysql', 'LOCK TABLES', '["server", "namespace"]', false, NULL, NULL, 'what LOCK TABLES lets its grantee do, as MySQL defines it'),
  ('mysql/ALTER', 'mysql', 'ALTER', '["server", "namespace", "object"]', false, NULL, NULL, 'what ALTER lets its grantee do, as MySQL defines it'),
  ('mysql/CREATE', 'mysql', 'CREATE', '["server", "namespace", "object"]', false, NULL, NULL, 'what CREATE lets its grantee do, as MySQL defines it'),
  ('mysql/CREATE VIEW', 'mysql', 'CREATE VIEW', '["server", "namespace", "object"]', false, NULL, NULL, 'what CREATE VIEW lets its grantee do, as MySQL defines it'),
  ('mysql/DELETE', 'mysql', 'DELETE', '["server", "namespace", "object"]', false, NULL, NULL, 'what DELETE lets its grantee do, as MySQL defines it'),
  ('mysql/DROP', 'mysql', 'DROP', '["server", "namespace", "object"]', false, NULL, NULL, 'what DROP lets its grantee do, as MySQL defines it'),
  ('mysql/INDEX', 'mysql', 'INDEX', '["server", "namespace", "object"]', false, NULL, NULL, 'what INDEX lets its grantee do, as MySQL defines it'),
  ('mysql/SHOW VIEW', 'mysql', 'SHOW VIEW', '["server", "namespace", "object"]', false, NULL, NULL, 'what SHOW VIEW lets its grantee do, as MySQL defines it'),
  ('mysql/TRIGGER', 'mysql', 'TRIGGER', '["server", "namespace", "object"]', false, NULL, NULL, 'what TRIGGER lets its grantee do, as MySQL defines it'),
  ('mysql/ALTER ROUTINE', 'mysql', 'ALTER ROUTINE', '["server", "namespace", "object"]', false, NULL, NULL, 'what ALTER ROUTINE lets its grantee do, as MySQL defines it'),
  ('mysql/EXECUTE', 'mysql', 'EXECUTE', '["server", "namespace", "object"]', false, NULL, NULL, 'what EXECUTE lets its grantee do, as MySQL defines it'),
  ('mysql/GRANT OPTION', 'mysql', 'GRANT OPTION', '["server", "namespace", "object"]', false, NULL, NULL, 'what GRANT OPTION lets its grantee do, as MySQL defines it'),
  ('mysql/USAGE', 'mysql', 'USAGE', '["server", "namespace", "object"]', false, NULL, NULL, 'what USAGE lets its grantee do, as MySQL defines it'),
  ('mysql/SELECT', 'mysql', 'SELECT', '["server", "namespace", "object", "column"]', false, NULL, NULL, 'what SELECT lets its grantee do, as MySQL defines it'),
  ('mysql/INSERT', 'mysql', 'INSERT', '["server", "namespace", "object", "column"]', false, NULL, NULL, 'what INSERT lets its grantee do, as MySQL defines it'),
  ('mysql/UPDATE', 'mysql', 'UPDATE', '["server", "namespace", "object", "column"]', false, NULL, NULL, 'what UPDATE lets its grantee do, as MySQL defines it'),
  ('mysql/REFERENCES', 'mysql', 'REFERENCES', '["server", "namespace", "object", "column"]', false, NULL, NULL, 'what REFERENCES lets its grantee do, as MySQL defines it'),
  ('mysql/dynamic', 'mysql', '^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$', '["server"]', true, 'mysql/8.0', NULL, 'a dynamic privilege, registered by the server or one of its components (BACKUP_ADMIN): an open set')
ON CONFLICT (id) DO NOTHING;
