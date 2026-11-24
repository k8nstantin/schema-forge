-- parts-only-in-their-kinds: An object has a part only when its kind's slots (object_kind_parts) hold that part: a view no keys, a table no query. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_parts_only_in_their_kinds AS
SELECT 'parts-only-in-their-kinds' AS rule, (p.id)::text AS id FROM cortex.table_keys p JOIN cortex.objects o ON o.id = p.object
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'keys')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.check_constraints p JOIN cortex.objects o ON o.id = p.object
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'checks')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.indexes p JOIN cortex.objects o ON o.id = p.object
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'indexes')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.table_partitionings p JOIN cortex.objects o ON o.id = p.id
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'partitioning')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.partition_parents p JOIN cortex.objects o ON o.id = p.id
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'partition_of')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.sort_fields p JOIN cortex.objects o ON o.id = p.object
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'order')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.view_queries p JOIN cortex.objects o ON o.id = p.id
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'query')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.sequences p JOIN cortex.objects o ON o.id = p.id
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'sequence')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.enum_values p JOIN cortex.objects o ON o.id = p.object
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'values')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.domains p JOIN cortex.objects o ON o.id = p.id
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'domain')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.composite_type_fields p JOIN cortex.objects o ON o.id = p.object
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'fields')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.routines p JOIN cortex.objects o ON o.id = p.id
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'routine')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.triggers p JOIN cortex.objects o ON o.id = p.id
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'trigger')
UNION ALL
SELECT 'parts-only-in-their-kinds', (p.id)::text FROM cortex.scheduled_events p JOIN cortex.objects o ON o.id = p.id
  WHERE NOT EXISTS (SELECT 1 FROM cortex.object_kind_parts k WHERE k.kind = o.kind AND k.slot = 'event');

COMMENT ON VIEW cortex.broken_parts_only_in_their_kinds IS 'An object has a part only when its kind''s slots (object_kind_parts) hold that part: a view no keys, a table no query.';
