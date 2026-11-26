-- facts-on-designs-of-the-engine: Every row of PostgreSQL's own tables belongs to a part of a PostgreSQL design. Owner: engine_postgresql.
-- The rows breaking it. cortex.enforce_rules('engine_postgresql') makes the database refuse any commit while it has one.
CREATE VIEW engine_postgresql.broken_facts_on_designs_of_the_engine AS
SELECT 'facts-on-designs-of-the-engine' AS rule, x.id AS id FROM (
  WITH oe AS (SELECT o.id, d.engine FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace JOIN cortex.designs d ON d.id = n.design),
  ne AS (SELECT n.id, d.engine FROM cortex.namespaces n JOIN cortex.designs d ON d.id = n.design),
  ce AS (SELECT c.id, oe.engine FROM cortex.columns c JOIN oe ON oe.id = c.object),
  ie AS (SELECT i.id, oe.engine FROM cortex.indexes i JOIN oe ON oe.id = i.object),
  pe AS (SELECT p.id, ie.engine FROM cortex.index_parts p JOIN ie ON ie.id = p."index"),
  ke AS (SELECT k.id, oe.engine FROM cortex.constraints k JOIN oe ON oe.id = k.object)
  SELECT (x.id)::text AS id FROM engine_postgresql.collations x JOIN ne ON ne.id = x.namespace WHERE ne.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.columns x JOIN ce ON ce.id = x.id WHERE ce.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.constraints x JOIN ke ON ke.id = x.id WHERE ke.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.index_parts x JOIN pe ON pe.id = x.id WHERE pe.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.indexes x JOIN ie ON ie.id = x.id WHERE ie.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.inheritance x JOIN oe ON oe.id = x.object WHERE oe.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.namespaces x JOIN ne ON ne.id = x.id WHERE ne.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.policies x JOIN oe ON oe.id = x.object WHERE oe.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.relations x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.routines x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.rules x JOIN oe ON oe.id = x.object WHERE oe.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.sequences x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.triggers x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'postgresql'
  UNION ALL
  SELECT (x.id)::text FROM engine_postgresql.types x JOIN oe ON oe.id = x.id WHERE oe.engine <> 'postgresql'
) x;

COMMENT ON VIEW engine_postgresql.broken_facts_on_designs_of_the_engine IS 'Every row of PostgreSQL''s own tables belongs to a part of a PostgreSQL design.';
