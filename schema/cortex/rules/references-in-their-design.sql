-- references-in-their-design: Every reference from one part of a design to another stays in that design: an object's parent, a link's table, a key's index, a dependency, an identity's or a sequence's column, a partition's table and a verbatim statement's place. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_references_in_their_design AS
SELECT 'references-in-their-design' AS rule, x.id AS id FROM (
  WITH od AS (SELECT o.id, n.design FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace),
  cd AS (SELECT c.id, od.design FROM cortex.columns c JOIN od ON od.id = c.object),
  id_ AS (SELECT i.id, od.design FROM cortex.indexes i JOIN od ON od.id = i.object)
  SELECT (o.id)::text AS id FROM cortex.objects o JOIN od a ON a.id = o.id JOIN od b ON b.id = o.parent WHERE a.design <> b.design
  UNION ALL
  SELECT (k.id)::text FROM cortex.constraints k JOIN od a ON a.id = k.object
    WHERE a.design <> (SELECT design FROM od WHERE id = k.to_object) OR a.design <> (SELECT design FROM id_ WHERE id = k."index")
  UNION ALL
  SELECT (x.id)::text FROM cortex.dependencies x JOIN od a ON a.id = x.object JOIN od b ON b.id = x.uses WHERE a.design <> b.design
  UNION ALL
  SELECT (x.id)::text FROM cortex.column_identities x JOIN cd a ON a.id = x.id JOIN od b ON b.id = x.sequence WHERE a.design <> b.design
  UNION ALL
  SELECT (x.id)::text FROM cortex.sequences x JOIN od a ON a.id = x.id JOIN cd b ON b.id = x.owned_by WHERE a.design <> b.design
  UNION ALL
  SELECT (x.id)::text FROM cortex.partitions x JOIN od a ON a.id = x.partitioning JOIN od b ON b.id = x.table_object WHERE a.design <> b.design
  UNION ALL
  SELECT (v.id)::text FROM cortex.verbatim_statements v
    WHERE v.design <> (SELECT design FROM cortex.namespaces WHERE id = v.after_namespace) OR v.design <> (SELECT design FROM od WHERE id = v.after_object)
) x;

COMMENT ON VIEW cortex.broken_references_in_their_design IS 'Every reference from one part of a design to another stays in that design: an object''s parent, a link''s table, a key''s index, a dependency, an identity''s or a sequence''s column, a partition''s table and a verbatim statement''s place.';
