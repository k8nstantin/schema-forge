-- ids-within-their-counters: A numbered part's number was given by its counter (the cortex's id_counters), so it is never given again. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_ids_within_their_counters AS
SELECT 'ids-within-their-counters' AS rule, (p.id)::text AS id FROM (
  SELECT id FROM engine_mysql.outside_references
  UNION ALL SELECT id FROM engine_mysql.merge_tables
  UNION ALL SELECT id FROM engine_mysql.routine_imports
  UNION ALL SELECT id FROM engine_mysql.subpartitions
  UNION ALL SELECT id FROM engine_mysql.view_column_names
) p LEFT JOIN cortex.id_counters c ON c.id = rtrim(p.id, '0123456789')
  WHERE c.id IS NULL OR c.last < CAST(substr(p.id, length(rtrim(p.id, '0123456789')) + 1) AS INTEGER);

COMMENT ON VIEW engine_mysql.broken_ids_within_their_counters IS 'A numbered part''s number was given by its counter (the cortex''s id_counters), so it is never given again.';
