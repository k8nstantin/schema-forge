-- event-and-trigger-context: time_zone and disabled_on_replica belong to an event, follows and precedes to a trigger. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_event_and_trigger_context AS
SELECT 'event-and-trigger-context' AS rule, (p.id)::text AS id FROM engine_mysql.program_context p JOIN cortex.objects o ON o.id = p.id
  WHERE (o.kind <> 'event' AND (p.time_zone IS NOT NULL OR p.disabled_on_replica IS NOT NULL))
     OR (o.kind <> 'trigger' AND (p.follows IS NOT NULL OR p.precedes IS NOT NULL));

COMMENT ON VIEW engine_mysql.broken_event_and_trigger_context IS 'time_zone and disabled_on_replica belong to an event, follows and precedes to a trigger.';
