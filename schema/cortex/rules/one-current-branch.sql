-- one-current-branch: Once work on a design has begun, exactly one of its branches is the one it is on. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_one_current_branch AS
SELECT 'one-current-branch' AS rule, (b.id)::text AS id FROM cortex.branches b
  WHERE (SELECT count(*) FROM cortex.branches x WHERE x.design = b.design AND x.current) <> 1;

COMMENT ON VIEW cortex.broken_one_current_branch IS 'Once work on a design has begun, exactly one of its branches is the one it is on.';
