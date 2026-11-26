-- tables-have-their-options: Every table has its engine and collation. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_tables_have_their_options AS
SELECT 'tables-have-their-options' AS rule, (o.id)::text AS id FROM cortex.objects o WHERE o.kind = 'table' AND NOT EXISTS (SELECT 1 FROM engine_mysql.tables t WHERE t.id = o.id);

COMMENT ON VIEW engine_mysql.broken_tables_have_their_options IS 'Every table has its engine and collation.';
