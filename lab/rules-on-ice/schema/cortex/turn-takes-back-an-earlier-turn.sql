-- turn-takes-back-an-earlier-turn: A turn that undoes takes back a turn made before it. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_turn_takes_back_an_earlier_turn AS
SELECT 'turn-takes-back-an-earlier-turn' AS rule, (t.id)::text AS id FROM cortex.turns t WHERE t.undoes IS NOT NULL AND t.undoes >= t.id;

COMMENT ON VIEW cortex.broken_turn_takes_back_an_earlier_turn IS 'A turn that undoes takes back a turn made before it.';
