-- links-have-columns: Every key and every link has at least one column. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_links_have_columns AS
SELECT 'links-have-columns' AS rule, (k.id)::text AS id FROM cortex.constraints k
  WHERE k.kind IN ('primary', 'unique', 'foreign', 'identifier') AND NOT EXISTS (SELECT 1 FROM cortex.constraint_columns x WHERE x."constraint" = k.id);

COMMENT ON VIEW cortex.broken_links_have_columns IS 'Every key and every link has at least one column.';
