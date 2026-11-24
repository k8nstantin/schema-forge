-- program-context-on-programs: A program context belongs to a view, procedure, function, trigger, event or library. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_program_context_on_programs AS
SELECT 'program-context-on-programs' AS rule, (p.id)::text AS id FROM engine_mysql.program_context p JOIN cortex.objects o ON o.id = p.id
  WHERE o.kind NOT IN ('view', 'procedure', 'function', 'trigger', 'event', 'library');

COMMENT ON VIEW engine_mysql.broken_program_context_on_programs IS 'A program context belongs to a view, procedure, function, trigger, event or library.';
