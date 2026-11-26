-- designs-of-a-declared-version: Every design is of an engine version its engine declares. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_designs_of_a_declared_version AS
SELECT 'designs-of-a-declared-version' AS rule, (d.id)::text AS id FROM cortex.designs d
  WHERE NOT EXISTS (SELECT 1 FROM cortex.engine_versions v WHERE v.engine = d.engine AND v.version = d.engine_version);

COMMENT ON VIEW cortex.broken_designs_of_a_declared_version IS 'Every design is of an engine version its engine declares.';
