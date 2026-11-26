-- tables-have-their-options: Every table of a MySQL design has its engine and collation. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_tables_have_their_options AS
SELECT 'tables-have-their-options' AS rule, (o.id)::text AS id FROM cortex.objects o
  JOIN cortex.namespaces n ON n.id = o.namespace JOIN cortex.designs d ON d.id = n.design
  WHERE d.engine = 'mysql' AND o.kind = 'table' AND NOT EXISTS (SELECT 1 FROM engine_mysql.tables t WHERE t.id = o.id);

COMMENT ON VIEW engine_mysql.broken_tables_have_their_options IS 'Every table of a MySQL design has its engine and collation.';
