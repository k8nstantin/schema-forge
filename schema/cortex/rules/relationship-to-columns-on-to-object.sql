-- relationship-to-columns-on-to-object: Every to_column of a relationship is a column of its to_object. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_relationship_to_columns_on_to_object AS
SELECT 'relationship-to-columns-on-to-object' AS rule, (lc.id)::text AS id FROM cortex.relationship_columns lc JOIN cortex.relationships l ON l.id = lc.relationship
  JOIN cortex.columns c ON c.id = lc.to_column WHERE c.object <> l.to_object;

COMMENT ON VIEW cortex.broken_relationship_to_columns_on_to_object IS 'Every to_column of a relationship is a column of its to_object.';
