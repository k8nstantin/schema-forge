-- cortex.log_row: the log's only writer. On every table of the model and of every plugin, after each row is inserted,
-- updated or deleted, it writes the row's change to cortex.row_changes under the operation the session is working in
-- (the setting schema_forge.operation, set by whoever runs the operation). A change made outside an operation is
-- refused: every change belongs to a turn. It runs as the cortex's owner, so no account writes the log itself.
-- One exception: a row deleted because its design is deleted (the cascade from cortex.designs) is not logged, since the
-- design's whole log goes with it; only the app may delete a design.

CREATE FUNCTION cortex.log_row() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cortex AS $$
DECLARE
  op   uuid := nullif(current_setting('schema_forge.operation', true), '')::uuid;
  old_row jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
  new_row jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM cortex.designs WHERE id = (old_row ->> 'design')::uuid) THEN
    RETURN NULL;   -- its design is being deleted: the design's whole log goes with it
  END IF;
  IF op IS NULL THEN
    RAISE EXCEPTION 'a change to %.% outside an operation: set schema_forge.operation first', TG_TABLE_SCHEMA, TG_TABLE_NAME
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'UPDATE' AND old_row = new_row THEN
    RETURN NULL;
  END IF;
  INSERT INTO cortex.row_changes (design, operation, tab, row_id, action, before, after)
  VALUES ((coalesce(new_row, old_row) ->> 'design')::uuid, op, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
          (coalesce(new_row, old_row) ->> 'id')::uuid, lower(TG_OP), old_row, new_row);
  RETURN NULL;
END $$;

COMMENT ON FUNCTION cortex.log_row() IS 'writes every change of a model or plugin row to cortex.row_changes under the session''s operation; refuses a change made outside one';
