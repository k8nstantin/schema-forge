-- primary-key-columns-not-null: Every column of a primary key holds no null. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_primary_key_columns_not_null AS
SELECT 'primary-key-columns-not-null' AS rule, (c.id)::text AS id FROM cortex.constraint_columns x JOIN cortex.constraints k ON k.id = x."constraint"
  JOIN cortex.columns c ON c.id = x."column" WHERE k.kind = 'primary' AND c.nullable;

COMMENT ON VIEW cortex.broken_primary_key_columns_not_null IS 'Every column of a primary key holds no null.';
