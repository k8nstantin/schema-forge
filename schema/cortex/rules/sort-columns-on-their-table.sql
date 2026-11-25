-- sort-columns-on-their-table: Every column a table's rows are ordered by is a column of that table. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_sort_columns_on_their_table AS
SELECT 'sort-columns-on-their-table' AS rule, (s.id)::text AS id FROM cortex.sort_fields s JOIN cortex.columns c ON c.id = s."column" WHERE c.object <> s.object;

COMMENT ON VIEW cortex.broken_sort_columns_on_their_table IS 'Every column a table''s rows are ordered by is a column of that table.';
