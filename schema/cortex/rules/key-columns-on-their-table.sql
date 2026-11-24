-- key-columns-on-their-table: Every column of a key is a column of the key's table. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_key_columns_on_their_table AS
SELECT 'key-columns-on-their-table' AS rule, (kc.id)::text AS id FROM cortex.table_key_columns kc JOIN cortex.table_keys k ON k.id = kc.key
  JOIN cortex.columns c ON c.id = kc."column" WHERE c.object <> k.object;

COMMENT ON VIEW cortex.broken_key_columns_on_their_table IS 'Every column of a key is a column of the key''s table.';
