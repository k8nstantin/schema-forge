-- kinds-of-their-tables: A loadable function, a tablespace and a spatial reference system are rows of objects of their own kind. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_kinds_of_their_tables AS
SELECT 'kinds-of-their-tables' AS rule, (x.id)::text AS id FROM engine_mysql.loadable_functions x JOIN cortex.objects o ON o.id = x.id WHERE o.kind <> 'loadable_function'
UNION ALL
SELECT 'kinds-of-their-tables', (x.id)::text FROM engine_mysql.tablespaces x JOIN cortex.objects o ON o.id = x.id WHERE o.kind <> 'tablespace'
UNION ALL
SELECT 'kinds-of-their-tables', (x.id)::text FROM engine_mysql.spatial_reference_systems x JOIN cortex.objects o ON o.id = x.id WHERE o.kind <> 'spatial_reference_system';

COMMENT ON VIEW engine_mysql.broken_kinds_of_their_tables IS 'A loadable function, a tablespace and a spatial reference system are rows of objects of their own kind.';
