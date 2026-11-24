-- features-since-before-until: A feature's first version is not after its last. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_features_since_before_until AS
SELECT 'features-since-before-until' AS rule, (f.id)::text AS id FROM cortex.engine_features f JOIN cortex.engine_versions s ON s.id = f.since JOIN cortex.engine_versions u ON u.id = f."until" WHERE s.position > u.position;

COMMENT ON VIEW cortex.broken_features_since_before_until IS 'A feature''s first version is not after its last.';
