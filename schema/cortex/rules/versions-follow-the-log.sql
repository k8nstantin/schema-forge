-- versions-follow-the-log: A higher version holds a later operation. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_versions_follow_the_log AS
SELECT 'versions-follow-the-log' AS rule, (b.id)::text AS id FROM cortex.locked_versions a JOIN cortex.locked_versions b ON b.number = a.number + 1
  WHERE b.at_operation <= a.at_operation;

COMMENT ON VIEW cortex.broken_versions_follow_the_log IS 'A higher version holds a later operation.';
