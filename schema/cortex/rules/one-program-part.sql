-- one-program-part: An object holds at most one of a query, a routine, a trigger, an event, a sequence and a domain. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_one_program_part AS
SELECT 'one-program-part' AS rule, (o.id)::text AS id FROM cortex.objects o WHERE
  (o.id IN (SELECT id FROM cortex.view_queries))::int + (o.id IN (SELECT id FROM cortex.routines))::int + (o.id IN (SELECT id FROM cortex.triggers))::int
  + (o.id IN (SELECT id FROM cortex.scheduled_events))::int + (o.id IN (SELECT id FROM cortex.sequences))::int + (o.id IN (SELECT id FROM cortex.domains))::int > 1;

COMMENT ON VIEW cortex.broken_one_program_part IS 'An object holds at most one of a query, a routine, a trigger, an event, a sequence and a domain.';
