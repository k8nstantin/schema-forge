-- cortex.undo: undoes a committed turn by applying the inverse of each of its row changes, newest first, as the
-- operation the session is working in (so the undo is itself logged, and can be undone); the operation records the
-- turn it undid. Then every turn of the design is marked by whether its changes are in the model: a turn is undone
-- when an undo in effect undid it, and in effect (committed) otherwise, worked out newest first, since an undo always
-- undoes an older turn. So undoing an undo brings its turn back, and undoing a restore brings back exactly what the
-- restore had undone, the undos among it included. Restore and branch switch are undos of the turns since the turn
-- wanted, newest first, until none after it is in effect. It runs as the cortex's owner, the one generic writer of
-- every engine's rows (decision plugin-writes): each plugin lets it write its tables for this alone, and only the app
-- and the agent may call it (they see every design).

CREATE FUNCTION cortex.undo(turn uuid) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cortex AS $$
DECLARE
  op    uuid := nullif(current_setting('schema_forge.operation', true), '')::uuid;
  d     uuid := (SELECT design FROM cortex.turns WHERE id = undo.turn);
  gone  uuid[] := '{}';
  x     record;
  c     record;
  cols  text;
  n     integer := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cortex.turns WHERE id = undo.turn AND state = 'committed') THEN
    RAISE EXCEPTION 'undo: turn % is not a committed turn', undo.turn;
  END IF;
  IF op IS NULL THEN
    RAISE EXCEPTION 'undo: outside an operation: set schema_forge.operation first' USING ERRCODE = 'insufficient_privilege';
  END IF;
  FOR c IN SELECT r.* FROM cortex.row_changes r JOIN cortex.operations o ON o.id = r.operation
            WHERE o.turn = undo.turn ORDER BY r.id DESC LOOP
    SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO cols FROM pg_attribute
     WHERE attrelid = c.tab::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = '';
    IF c.action = 'insert' THEN
      EXECUTE format('DELETE FROM %s WHERE id = $1', c.tab) USING c.row_id;
    ELSIF c.action = 'delete' THEN
      EXECUTE format('INSERT INTO %s (%s) SELECT %s FROM jsonb_populate_record(NULL::%s, $1)', c.tab, cols, cols, c.tab) USING c.before;
    ELSE
      EXECUTE format('UPDATE %s SET (%s) = (SELECT %s FROM jsonb_populate_record(NULL::%s, $1)) WHERE id = $2', c.tab, cols, cols, c.tab)
        USING c.before, c.row_id;
    END IF;
    n := n + 1;
  END LOOP;
  UPDATE cortex.operations SET undoes = undo.turn WHERE id = op;
  -- every turn's state from the undos in effect, newest first (the open turn, this undo's, is the newest)
  FOR x IN SELECT id, state FROM cortex.turns WHERE design = d AND state IN ('open', 'committed', 'undone')
            ORDER BY seq DESC NULLS FIRST LOOP
    IF x.id = ANY (gone) THEN
      IF x.state = 'committed' THEN
        UPDATE cortex.turns SET state = 'undone' WHERE id = x.id;
      END IF;
    ELSE
      IF x.state = 'undone' THEN
        UPDATE cortex.turns SET state = 'committed' WHERE id = x.id;
      END IF;
      gone := gone || ARRAY(SELECT o.undoes FROM cortex.operations o WHERE o.turn = x.id AND o.undoes IS NOT NULL);
    END IF;
  END LOOP;
  RETURN n;
END $$;

COMMENT ON FUNCTION cortex.undo(uuid) IS 'undoes a committed turn: the inverse of each of its row changes, newest first, logged under the current operation, which records the turn undone; then marks every turn of the design undone or committed by whether an undo in effect undid it';
