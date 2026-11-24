-- relationship-from-columns-on-from-object: Every from_column of a relationship is a column of its from_object. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_relationship_from_columns_on_from_object AS
SELECT 'relationship-from-columns-on-from-object' AS rule, (lc.id)::text AS id FROM cortex.relationship_columns lc JOIN cortex.relationships l ON l.id = lc.relationship
  JOIN cortex.columns c ON c.id = lc.from_column WHERE c.object <> l.from_object;

COMMENT ON VIEW cortex.broken_relationship_from_columns_on_from_object IS 'Every from_column of a relationship is a column of its from_object.';
