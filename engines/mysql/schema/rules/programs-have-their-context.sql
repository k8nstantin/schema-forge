-- programs-have-their-context: Every view, routine, trigger and event has what MySQL made it under: its definer, sql_mode and character set. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_programs_have_their_context AS
SELECT 'programs-have-their-context' AS rule, (o.id)::text AS id FROM cortex.objects o
  WHERE o.kind IN ('view', 'procedure', 'function', 'trigger', 'event') AND NOT EXISTS (SELECT 1 FROM engine_mysql.programs p WHERE p.id = o.id);

COMMENT ON VIEW engine_mysql.broken_programs_have_their_context IS 'Every view, routine, trigger and event has what MySQL made it under: its definer, sql_mode and character set.';
