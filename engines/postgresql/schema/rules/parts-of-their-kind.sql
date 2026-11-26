-- parts-of-their-kind: A relation's facts are a table's, a view's, a materialized view's or a sequence's, and a type's facts a type's, each on an object of a PostgreSQL design. Owner: engine_postgresql.
-- The rows breaking it. cortex.enforce_rules('engine_postgresql') makes the database refuse any commit while it has one.
CREATE VIEW engine_postgresql.broken_parts_of_their_kind AS
SELECT 'parts-of-their-kind' AS rule, (x.id)::text AS id FROM (
  SELECT id, ARRAY['table', 'view', 'materialized_view', 'sequence'] AS kinds FROM engine_postgresql.relations
  UNION ALL SELECT id, ARRAY['enum', 'composite', 'domain', 'range'] FROM engine_postgresql.types
) x JOIN cortex.objects o ON o.id = x.id
  JOIN cortex.namespaces n ON n.id = o.namespace JOIN cortex.designs d ON d.id = n.design
  WHERE o.kind <> ALL (x.kinds) OR d.engine <> 'postgresql';

COMMENT ON VIEW engine_postgresql.broken_parts_of_their_kind IS 'A relation''s facts are a table''s, a view''s, a materialized view''s or a sequence''s, and a type''s facts a type''s, each on an object of a PostgreSQL design.';
