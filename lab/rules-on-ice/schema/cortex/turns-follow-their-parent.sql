-- turns-follow-their-parent: A turn follows a turn made before it. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_turns_follow_their_parent AS
SELECT 'turns-follow-their-parent' AS rule, (t.id)::text AS id FROM cortex.turns t JOIN cortex.turns p ON p.id = t.parent WHERE p.id >= t.id;

COMMENT ON VIEW cortex.broken_turns_follow_their_parent IS 'A turn follows a turn made before it.';
