-- relationship-has-columns: Every relationship joins at least one column. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_relationship_has_columns AS
SELECT 'relationship-has-columns' AS rule, (l.id)::text AS id FROM cortex.relationships l WHERE NOT EXISTS (SELECT 1 FROM cortex.relationship_columns lc WHERE lc.relationship = l.id);

COMMENT ON VIEW cortex.broken_relationship_has_columns IS 'Every relationship joins at least one column.';
