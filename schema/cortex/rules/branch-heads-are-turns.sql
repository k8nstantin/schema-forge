-- branch-heads-are-turns: A branch's newest turn is a turn: its own newest, or the turn it forks from before it has one. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_branch_heads_are_turns AS
SELECT 'branch-heads-are-turns' AS rule, (b.id)::text AS id FROM cortex.branches b
  WHERE b.head IS NOT NULL AND NOT EXISTS (SELECT 1 FROM cortex.turns t WHERE t.id = b.head);

COMMENT ON VIEW cortex.broken_branch_heads_are_turns IS 'A branch''s newest turn is a turn: its own newest, or the turn it forks from before it has one.';
