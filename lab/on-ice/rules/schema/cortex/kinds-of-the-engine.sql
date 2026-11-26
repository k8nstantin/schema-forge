-- kinds-of-the-engine: An object's kind is one its design's engine declares. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_kinds_of_the_engine AS
SELECT 'kinds-of-the-engine' AS rule, (o.id)::text AS id FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace
  JOIN cortex.designs d ON d.id = n.design WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kinds k WHERE k.engine = d.engine AND k.kind = o.kind);

COMMENT ON VIEW cortex.broken_kinds_of_the_engine IS 'An object''s kind is one its design''s engine declares.';
