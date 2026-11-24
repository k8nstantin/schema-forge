-- operation-after-its-turn: An operation's id is after its turn's id: a turn begins with its first operation. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_operation_after_its_turn AS
SELECT 'operation-after-its-turn' AS rule, (o.id)::text AS id FROM cortex.operations o WHERE o.id < o.turn;

COMMENT ON VIEW cortex.broken_operation_after_its_turn IS 'An operation''s id is after its turn''s id: a turn begins with its first operation.';
