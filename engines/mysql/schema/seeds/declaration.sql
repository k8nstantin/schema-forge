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

INSERT INTO cortex.object_kinds (id, engine, kind, name, position) VALUES
  ('mysql/table', 'mysql', 'table', 'Table', 1),
  ('mysql/view', 'mysql', 'view', 'View', 2),
  ('mysql/procedure', 'mysql', 'procedure', 'Procedure', 3),
  ('mysql/function', 'mysql', 'function', 'Function', 4),
  ('mysql/loadable_function', 'mysql', 'loadable_function', 'Loadable function', 5),
  ('mysql/library', 'mysql', 'library', 'Library', 6),
  ('mysql/trigger', 'mysql', 'trigger', 'Trigger', 7),
  ('mysql/event', 'mysql', 'event', 'Event', 8),
  ('mysql/tablespace', 'mysql', 'tablespace', 'Tablespace', 9),
  ('mysql/spatial_reference_system', 'mysql', 'spatial_reference_system', 'Spatial reference system', 10)
ON CONFLICT (id) DO NOTHING;

INSERT INTO cortex.option_declarations (id, engine, part, name, value_type, nullable, choices, since, about) VALUES
  ('mysql/objects/language', 'mysql', 'objects', 'language', 'string', false, NULL, 'mysql/9.7', 'a library''s language, as SHOW CREATE LIBRARY writes it (JAVASCRIPT)'),
  ('mysql/dependencies/alias', 'mysql', 'dependencies', 'alias', 'string', true, NULL, 'mysql/9.7', 'the name a routine''s code calls a library it uses by (USING (lib AS util)); NULL for the library''s own name')
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
  ('mysql/objects/definer', 'mysql', 'objects', 'definer', 'string', false, NULL, 'the account whose rights it runs with, as the server gives it (app@%)'),
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
  ('mysql/objects/tablespace', 'mysql', 'objects', 'tablespace', 'string', true, NULL, 'the tablespace it is stored in, where written'),
  ('mysql/objects/insert_method', 'mysql', 'objects', 'insert_method', 'string', true, NULL, 'a MERGE table''s INSERT_METHOD; its tables are dependencies, in order'),
  ('mysql/views/algorithm', 'mysql', 'views', 'algorithm', 'string', false, '["UNDEFINED", "MERGE", "TEMPTABLE"]', 'how its query is run: SHOW CREATE VIEW alone holds it'),
  ('mysql/views/security', 'mysql', 'views', 'security', 'string', false, '["DEFINER", "INVOKER"]', 'whose rights it runs with')
ON CONFLICT (id) DO NOTHING;
