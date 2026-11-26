-- usage-in-its-design: A snapshot's usage names objects and indexes of the design it was read for. Owner: usage.
-- The rows breaking it. cortex.enforce_rules('usage') makes the database refuse any commit while it has one.
CREATE VIEW usage.broken_usage_in_its_design AS
SELECT 'usage-in-its-design' AS rule, x.id AS id FROM (
  WITH od AS (SELECT o.id, n.design FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace),
  sd AS (SELECT s.id, r.design FROM usage.snapshots s JOIN cortex.source_reads r ON r.id = s.source_read)
  SELECT (u.id)::text AS id FROM usage.object_usage u JOIN sd ON sd.id = u.snapshot JOIN od ON od.id = u.object WHERE od.design <> sd.design
  UNION ALL
  SELECT (u.id)::text FROM usage.index_usage u JOIN sd ON sd.id = u.snapshot
    JOIN cortex.indexes i ON i.id = u."index" JOIN od ON od.id = i.object WHERE od.design <> sd.design
) x;

COMMENT ON VIEW usage.broken_usage_in_its_design IS 'A snapshot''s usage names objects and indexes of the design it was read for.';
