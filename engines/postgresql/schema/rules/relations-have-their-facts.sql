-- relations-have-their-facts: Every table, view, materialized view and sequence has its persistence, owner and privileges. Owner: engine_postgresql.
-- The rows breaking it. cortex.enforce_rules('engine_postgresql') makes the database refuse any commit while it has one.
CREATE VIEW engine_postgresql.broken_relations_have_their_facts AS
SELECT 'relations-have-their-facts' AS rule, (o.id)::text AS id FROM cortex.objects o
  WHERE o.kind IN ('table', 'view', 'materialized_view', 'sequence') AND NOT EXISTS (SELECT 1 FROM engine_postgresql.relations r WHERE r.id = o.id);

COMMENT ON VIEW engine_postgresql.broken_relations_have_their_facts IS 'Every table, view, materialized view and sequence has its persistence, owner and privileges.';
