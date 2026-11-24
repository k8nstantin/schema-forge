-- index-usage-on-its-table: An index's usage names the table its design index is on. Owner: usage.
-- The rows breaking it. cortex.enforce_rules('usage') makes the database refuse any commit while it has one.
CREATE VIEW usage.broken_index_usage_on_its_table AS
SELECT 'index-usage-on-its-table' AS rule, (u.id)::text AS id FROM usage.index_usage u JOIN cortex.indexes i ON i.id = u."index" JOIN cortex.objects o ON o.id = i.object WHERE o.name <> u.object_name;

COMMENT ON VIEW usage.broken_index_usage_on_its_table IS 'An index''s usage names the table its design index is on.';
