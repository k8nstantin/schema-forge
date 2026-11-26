-- references-in-their-design: A partition index's parent index and a table's inherited parent are in the table's own design. Owner: engine_postgresql.
-- The rows breaking it. cortex.enforce_rules('engine_postgresql') makes the database refuse any commit while it has one.
CREATE VIEW engine_postgresql.broken_references_in_their_design AS
SELECT 'references-in-their-design' AS rule, x.id AS id FROM (
  WITH od AS (SELECT o.id, n.design FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace),
  id_ AS (SELECT i.id, od.design FROM cortex.indexes i JOIN od ON od.id = i.object)
  SELECT (x.id)::text AS id FROM engine_postgresql.indexes x JOIN id_ a ON a.id = x.id JOIN id_ b ON b.id = x.parent WHERE a.design <> b.design
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.inheritance x JOIN od a ON a.id = x.object JOIN od b ON b.id = x.parent WHERE a.design <> b.design
) x;

COMMENT ON VIEW engine_postgresql.broken_references_in_their_design IS 'A partition index''s parent index and a table''s inherited parent are in the table''s own design.';
