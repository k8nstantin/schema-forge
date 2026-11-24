-- ids-within-their-counters: A numbered part's number was given by its counter: the counter exists and is at least the number, so it is never given again. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_ids_within_their_counters AS
SELECT 'ids-within-their-counters' AS rule, (p.id)::text AS id FROM (
  SELECT id FROM cortex.check_constraints
  UNION ALL SELECT id FROM cortex.composite_type_fields
  UNION ALL SELECT id FROM cortex.enum_values
  UNION ALL SELECT id FROM cortex.indexes
  UNION ALL SELECT id FROM cortex.object_tags
  UNION ALL SELECT id FROM cortex.object_reads
  UNION ALL SELECT id FROM cortex.partition_fields
  UNION ALL SELECT id FROM cortex.partitions
  UNION ALL SELECT id FROM cortex.routine_parameters
  UNION ALL SELECT id FROM cortex.table_keys
  UNION ALL SELECT id FROM cortex.sort_fields
  UNION ALL SELECT id FROM cortex.table_key_columns
  UNION ALL SELECT id FROM cortex.relationship_columns
  UNION ALL SELECT id FROM cortex.index_parts
  UNION ALL SELECT id FROM cortex.index_includes
  UNION ALL SELECT id FROM cortex.trigger_events
  UNION ALL SELECT id FROM cortex.verbatim_statements
) p LEFT JOIN cortex.id_counters c ON c.id = rtrim(p.id, '0123456789')
  WHERE c.id IS NULL OR c.last < CAST(substr(p.id, length(rtrim(p.id, '0123456789')) + 1) AS INTEGER);

COMMENT ON VIEW cortex.broken_ids_within_their_counters IS 'A numbered part''s number was given by its counter: the counter exists and is at least the number, so it is never given again.';
