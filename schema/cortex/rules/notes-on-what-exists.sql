-- notes-on-what-exists: A pinned note is pinned to something the design holds: its target, of its kind, exists. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_notes_on_what_exists AS
SELECT 'notes-on-what-exists' AS rule, (n.id)::text AS id FROM cortex.pinned_notes n
  WHERE NOT CASE n.target_kind
    WHEN 'schema' THEN n.target_id = 'schema' AND EXISTS (SELECT 1 FROM cortex.schema_identity)
    WHEN 'namespace' THEN EXISTS (SELECT 1 FROM cortex.namespaces x WHERE x.id = n.target_id)
    WHEN 'object' THEN EXISTS (SELECT 1 FROM cortex.objects x WHERE x.id = n.target_id)
    WHEN 'column' THEN EXISTS (SELECT 1 FROM cortex.columns x WHERE x.id = n.target_id)
    WHEN 'relationship' THEN EXISTS (SELECT 1 FROM cortex.relationships x WHERE x.id = n.target_id)
    WHEN 'area' THEN EXISTS (SELECT 1 FROM cortex.subject_areas x WHERE x.id = n.target_id)
    WHEN 'turn' THEN EXISTS (SELECT 1 FROM cortex.turns x WHERE x.id::text = n.target_id)
    WHEN 'locked_version' THEN EXISTS (SELECT 1 FROM cortex.locked_versions x WHERE x.id::text = n.target_id)
    ELSE n.target_id IN (SELECT id FROM cortex.table_keys UNION ALL SELECT id FROM cortex.check_constraints
      UNION ALL SELECT id FROM cortex.indexes UNION ALL SELECT id FROM cortex.partitions
      UNION ALL SELECT id FROM cortex.sort_fields UNION ALL SELECT id FROM cortex.enum_values
      UNION ALL SELECT id FROM cortex.composite_type_fields UNION ALL SELECT id FROM cortex.routine_parameters
      UNION ALL SELECT id FROM cortex.trigger_events UNION ALL SELECT id FROM cortex.verbatim_statements)
  END;

COMMENT ON VIEW cortex.broken_notes_on_what_exists IS 'A pinned note is pinned to something the design holds: its target, of its kind, exists.';
