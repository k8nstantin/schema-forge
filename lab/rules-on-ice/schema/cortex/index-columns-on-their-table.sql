-- index-columns-on-their-table: Every column an index orders by or carries is a column of the index's table. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_index_columns_on_their_table AS
SELECT 'index-columns-on-their-table' AS rule, (p.id)::text AS id FROM cortex.index_parts p JOIN cortex.indexes i ON i.id = p."index"
  JOIN cortex.columns c ON c.id = p."column" WHERE c.object <> i.object;

COMMENT ON VIEW cortex.broken_index_columns_on_their_table IS 'Every column an index orders by or carries is a column of the index''s table.';
