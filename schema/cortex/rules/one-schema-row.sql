-- one-schema-row: The database holds its schema's row (the table allows at most one). Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_one_schema_row AS
SELECT 'one-schema-row' AS rule, 'schema'::text AS id WHERE (SELECT count(*) FROM cortex.schema_identity) <> 1;

COMMENT ON VIEW cortex.broken_one_schema_row IS 'The database holds its schema''s row (the table allows at most one).';
