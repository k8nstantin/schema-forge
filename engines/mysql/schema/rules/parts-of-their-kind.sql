-- parts-of-their-kind: Table options are a table's, an event's schedule an event's, and a program's context a view's, a routine's, a trigger's or an event's, each on an object of a MySQL design. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_parts_of_their_kind AS
SELECT 'parts-of-their-kind' AS rule, (x.id)::text AS id FROM (
  SELECT id, ARRAY['table'] AS kinds FROM engine_mysql.tables
  UNION ALL SELECT id, ARRAY['event'] FROM engine_mysql.events
  UNION ALL SELECT id, ARRAY['view', 'procedure', 'function', 'trigger', 'event'] FROM engine_mysql.programs
) x JOIN cortex.objects o ON o.id = x.id
  JOIN cortex.namespaces n ON n.id = o.namespace JOIN cortex.designs d ON d.id = n.design
  WHERE o.kind <> ALL (x.kinds) OR d.engine <> 'mysql';

COMMENT ON VIEW engine_mysql.broken_parts_of_their_kind IS 'Table options are a table''s, an event''s schedule an event''s, and a program''s context a view''s, a routine''s, a trigger''s or an event''s, each on an object of a MySQL design.';
