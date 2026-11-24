-- nested-fields-in-their-column: A nested field sits in a field of the same column. Owner: engine_example.
-- The rows breaking it. cortex.enforce_rules('engine_example') makes the database refuse any commit while it has one.
CREATE VIEW engine_example.broken_nested_fields_in_their_column AS
SELECT 'nested-fields-in-their-column' AS rule, (f.id)::text AS id FROM engine_example.nested_fields f
  JOIN engine_example.nested_fields p ON p.id = f.parent WHERE p."column" <> f."column";

COMMENT ON VIEW engine_example.broken_nested_fields_in_their_column IS 'A nested field sits in a field of the same column.';
