-- cortex.undo: undoes a committed turn by applying the inverse of each of its row changes, newest first, as the
-- operation the session is working in (so the undo is itself logged, and can be undone); the turn is marked undone.
-- Restore and branch switch are undos of the turns since the turn wanted. It runs as the cortex's owner, the one generic
-- writer of every engine's rows (decision plugin-writes): each plugin lets it write its tables for this alone, and only
-- the app and the agent may call it (they see every design).

CREATE FUNCTION cortex.undo(turn uuid) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cortex AS $$
DECLARE
  c     record;
  cols  text;
  n     integer := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cortex.turns WHERE id = undo.turn AND state = 'committed') THEN
    RAISE EXCEPTION 'undo: turn % is not a committed turn', undo.turn;
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
  UPDATE cortex.turns SET state = 'undone' WHERE id = undo.turn;
  RETURN n;
END $$;

COMMENT ON FUNCTION cortex.undo(uuid) IS 'undoes a committed turn: the inverse of each of its row changes, newest first, logged under the current operation; marks the turn undone';
