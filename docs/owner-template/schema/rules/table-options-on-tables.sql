-- table-options-on-tables: Table options belong to an object of the kind table. Owner: engine_example.
-- The rows breaking it. cortex.enforce_rules('engine_example') makes the database refuse any commit while it has one.
CREATE VIEW engine_example.broken_table_options_on_tables AS
SELECT 'table-options-on-tables' AS rule, (t.id)::text AS id FROM engine_example.table_options t JOIN cortex.objects o ON o.id = t.id WHERE o.kind <> 'table';

COMMENT ON VIEW engine_example.broken_table_options_on_tables IS 'Table options belong to an object of the kind table.';
