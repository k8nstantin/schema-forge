-- versions-follow-the-log: Versions are numbered from 1 without a gap, and a higher version holds a later turn. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_versions_follow_the_log AS
SELECT 'versions-follow-the-log' AS rule, (b.id)::text AS id FROM cortex.locked_versions b
  WHERE (b.number > 1 AND NOT EXISTS (SELECT 1 FROM cortex.locked_versions a WHERE a.number = b.number - 1))
     OR EXISTS (SELECT 1 FROM cortex.locked_versions a WHERE a.number = b.number - 1 AND b.turn <= a.turn);

COMMENT ON VIEW cortex.broken_versions_follow_the_log IS 'Versions are numbered from 1 without a gap, and a higher version holds a later turn.';
