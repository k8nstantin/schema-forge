-- constraint-columns-on-their-tables: Every column of a key or link is a column of its table, and every column a link refers to is a column of the table it refers to. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_constraint_columns_on_their_tables AS
SELECT 'constraint-columns-on-their-tables' AS rule, (x.id)::text AS id FROM cortex.constraint_columns x JOIN cortex.constraints k ON k.id = x."constraint"
  JOIN cortex.columns c ON c.id = x."column" LEFT JOIN cortex.columns t ON t.id = x.to_column
  WHERE c.object <> k.object OR (t.id IS NOT NULL AND t.object IS DISTINCT FROM k.to_object);

COMMENT ON VIEW cortex.broken_constraint_columns_on_their_tables IS 'Every column of a key or link is a column of its table, and every column a link refers to is a column of the table it refers to.';
