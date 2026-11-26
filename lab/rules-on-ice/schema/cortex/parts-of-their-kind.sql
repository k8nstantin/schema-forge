-- parts-of-their-kind: A routine is a procedure or a function, a view a view or a materialized view, a trigger a trigger, a sequence a sequence, a partitioning on a table, a domain a domain. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_parts_of_their_kind AS
SELECT 'parts-of-their-kind' AS rule, (x.id)::text AS id FROM (
  SELECT id, ARRAY['procedure', 'function'] AS kinds FROM cortex.routines
  UNION ALL SELECT id, ARRAY['view', 'materialized_view'] FROM cortex.views
  UNION ALL SELECT id, ARRAY['trigger'] FROM cortex.triggers
  UNION ALL SELECT id, ARRAY['sequence'] FROM cortex.sequences
  UNION ALL SELECT id, ARRAY['table'] FROM cortex.partitionings
  UNION ALL SELECT id, ARRAY['domain'] FROM cortex.domains
) x JOIN cortex.objects o ON o.id = x.id WHERE o.kind <> ALL (x.kinds);

COMMENT ON VIEW cortex.broken_parts_of_their_kind IS 'A routine is a procedure or a function, a view a view or a materialized view, a trigger a trigger, a sequence a sequence, a partitioning on a table, a domain a domain.';
