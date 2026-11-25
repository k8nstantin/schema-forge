-- operation-after-its-turn: An operation is committed no earlier than its turn began. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_operation_after_its_turn AS
SELECT 'operation-after-its-turn' AS rule, (o.id)::text AS id FROM cortex.operations o JOIN cortex.turns t ON t.id = o.turn WHERE o.at < t.started_at;

COMMENT ON VIEW cortex.broken_operation_after_its_turn IS 'An operation is committed no earlier than its turn began.';
