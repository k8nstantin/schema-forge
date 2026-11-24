-- ids-within-their-counters: A numbered part's number was given by its counter (the cortex's id_counters), so it is never given again. Owner: engine_example.
-- The rows breaking it. cortex.enforce_rules('engine_example') makes the database refuse any commit while it has one.
CREATE VIEW engine_example.broken_ids_within_their_counters AS
SELECT 'ids-within-their-counters' AS rule, (p.id)::text AS id FROM (
  SELECT id FROM engine_example.column_codecs
  UNION ALL SELECT id FROM engine_example.table_properties
  UNION ALL SELECT id FROM engine_example.nested_fields
) p LEFT JOIN cortex.id_counters c ON c.id = rtrim(p.id, '0123456789')
  WHERE c.id IS NULL OR c.last < CAST(substr(p.id, length(rtrim(p.id, '0123456789')) + 1) AS INTEGER);

COMMENT ON VIEW engine_example.broken_ids_within_their_counters IS 'A numbered part''s number was given by its counter (the cortex''s id_counters), so it is never given again.';
