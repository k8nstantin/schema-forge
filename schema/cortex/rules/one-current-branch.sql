-- one-current-branch: Once work has begun, exactly one branch is the one the design is on. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_one_current_branch AS
SELECT 'one-current-branch' AS rule, (b.id)::text AS id FROM cortex.branches b
  WHERE (SELECT count(*) FROM cortex.branches x WHERE x.current) <> 1;

COMMENT ON VIEW cortex.broken_one_current_branch IS 'Once work has begun, exactly one branch is the one the design is on.';
