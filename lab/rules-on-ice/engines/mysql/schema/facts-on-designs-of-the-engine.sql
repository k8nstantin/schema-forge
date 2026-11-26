-- facts-on-designs-of-the-engine: Every row of MySQL's own tables belongs to a part of a MySQL design. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_facts_on_designs_of_the_engine AS
SELECT 'facts-on-designs-of-the-engine' AS rule, x.id AS id FROM (
  WITH oe AS (SELECT o.id, d.engine FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace JOIN cortex.designs d ON d.id = n.design),
  ne AS (SELECT n.id, d.engine FROM cortex.namespaces n JOIN cortex.designs d ON d.id = n.design),
  ce AS (SELECT c.id, oe.engine FROM cortex.columns c JOIN oe ON oe.id = c.object),
  ie AS (SELECT i.id, oe.engine FROM cortex.indexes i JOIN oe ON oe.id = i.object),
  pe AS (SELECT p.id, ie.engine FROM cortex.index_parts p JOIN ie ON ie.id = p."index"),
  te AS (SELECT p.id, oe.engine FROM cortex.partitions p JOIN oe ON oe.id = p.partitioning)
  SELECT (x.id)::text AS id FROM engine_mysql.columns x JOIN ce ON ce.id = x.id WHERE ce.engine <> 'mysql'
  UNION ALL
  SELECT (x.id)::text FROM engine_mysql.databases x JOIN ne ON ne.id = x.id WHERE ne.engine <> 'mysql'
  UNION ALL
  SELECT (x.id)::text FROM engine_mysql.events x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'mysql'
  UNION ALL
  SELECT (x.id)::text FROM engine_mysql.index_parts x JOIN pe ON pe.id = x.id WHERE pe.engine <> 'mysql'
  UNION ALL
  SELECT (x.id)::text FROM engine_mysql.indexes x JOIN ie ON ie.id = x.id WHERE ie.engine <> 'mysql'
  UNION ALL
  SELECT (x.id)::text FROM engine_mysql.programs x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'mysql'
  UNION ALL
  SELECT (x.id)::text FROM engine_mysql.routines x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'mysql'
  UNION ALL
  SELECT (x.id)::text FROM engine_mysql.subpartitionings x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'mysql'
  UNION ALL
  SELECT (x.id)::text FROM engine_mysql.subpartitions x JOIN te ON te.id = x."partition" WHERE te.engine <> 'mysql'
  UNION ALL
  SELECT (x.id)::text FROM engine_mysql.tables x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'mysql'
  UNION ALL
  SELECT (x.id)::text FROM engine_mysql.views x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'mysql'
) x;

COMMENT ON VIEW engine_mysql.broken_facts_on_designs_of_the_engine IS 'Every row of MySQL''s own tables belongs to a part of a MySQL design.';
