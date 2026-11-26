-- triggers-on-a-table: Every trigger belongs to a table or a view of its namespace. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_triggers_on_a_table AS
SELECT 'triggers-on-a-table' AS rule, (o.id)::text AS id FROM cortex.objects o LEFT JOIN cortex.objects t ON t.id = o.parent
  WHERE o.kind = 'trigger' AND (t.id IS NULL OR t.kind NOT IN ('table', 'view') OR t.namespace <> o.namespace);

COMMENT ON VIEW cortex.broken_triggers_on_a_table IS 'Every trigger belongs to a table or a view of its namespace.';
