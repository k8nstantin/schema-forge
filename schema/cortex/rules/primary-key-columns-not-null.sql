-- primary-key-columns-not-null: A column of a primary key never holds null. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_primary_key_columns_not_null AS
SELECT 'primary-key-columns-not-null' AS rule, (kc.id)::text AS id FROM cortex.table_key_columns kc JOIN cortex.table_keys k ON k.id = kc.key
  JOIN cortex.columns c ON c.id = kc."column" WHERE k.what = 'primary' AND c.nullable;

COMMENT ON VIEW cortex.broken_primary_key_columns_not_null IS 'A column of a primary key never holds null.';
