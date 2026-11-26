-- turns-on-their-design: A turn follows a turn of its own design, and a savepoint or version marks a turn of its own design. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_turns_on_their_design AS
SELECT 'turns-on-their-design' AS rule, (t.id)::text AS id FROM cortex.turns t JOIN cortex.branches b ON b.id = t.branch
  JOIN cortex.turns p ON p.id = t.parent JOIN cortex.branches pb ON pb.id = p.branch WHERE pb.design <> b.design
UNION ALL
SELECT 'turns-on-their-design', (s.id)::text FROM cortex.savepoints s JOIN cortex.turns t ON t.id = s.turn JOIN cortex.branches b ON b.id = t.branch WHERE b.design <> s.design
UNION ALL
SELECT 'turns-on-their-design', (v.id)::text FROM cortex.locked_versions v JOIN cortex.turns t ON t.id = v.turn JOIN cortex.branches b ON b.id = t.branch WHERE b.design <> v.design;

COMMENT ON VIEW cortex.broken_turns_on_their_design IS 'A turn follows a turn of its own design, and a savepoint or version marks a turn of its own design.';
