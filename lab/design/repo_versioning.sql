-- The log's working, on the locked design's own tables, versioning the cortex, the ui and every engine (cortex.branches, turns, operations, row_changes, savepoints,
-- locked_versions): what the store will do, written here to prove the tables carry it. Lab code, in its own schema
-- sf_log; it writes only the locked tables. Between turns the design holds its current branch's newest turn.

CREATE SCHEMA sf_log;

-- every table of the design the log keeps: the cortex's design, the ui and every engine's; never the log itself, nor
-- what the engine declares, what was applied or what was read
CREATE FUNCTION sf_log.versioned() RETURNS TABLE (tab text) LANGUAGE sql STABLE AS $$
  SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND (n.nspname LIKE 'engine\_%' OR n.nspname = 'ui' OR (n.nspname = 'cortex' AND c.relname NOT IN
    ('designs', 'engine_versions', 'engine_features', 'catalog_sources', 'object_kinds', 'schema_migrations',
     'source_reads', 'branches', 'turns', 'operations', 'row_changes', 'savepoints', 'locked_versions')
    AND c.relname NOT LIKE 'workspace\_%'))
  ORDER BY 1
$$;

CREATE FUNCTION sf_log.record() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  op uuid := nullif(current_setting('sf.operation', true), '')::uuid;
  o jsonb; n jsonb; b jsonb := '{}'; a jsonb := '{}'; k text;
  tab text := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
BEGIN
  IF current_setting('sf.replaying', true) = 'on' THEN RETURN NULL; END IF;
  IF op IS NULL THEN RAISE EXCEPTION 'a change outside a turn: begin one with sf_log.begin_turn'; END IF;
  IF TG_OP = 'INSERT' THEN
    INSERT INTO cortex.row_changes (operation, table_name, row_id, action, after) VALUES (op, tab, NEW.id, 'insert', to_jsonb(NEW));
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO cortex.row_changes (operation, table_name, row_id, action, before) VALUES (op, tab, OLD.id, 'delete', to_jsonb(OLD));
  ELSE
    o := to_jsonb(OLD); n := to_jsonb(NEW);
    FOR k IN SELECT jsonb_object_keys(n) LOOP
      IF o -> k IS DISTINCT FROM n -> k THEN b := b || jsonb_build_object(k, o -> k); a := a || jsonb_build_object(k, n -> k); END IF;
    END LOOP;
    IF a <> '{}' THEN
      INSERT INTO cortex.row_changes (operation, table_name, row_id, action, before, after) VALUES (op, tab, OLD.id, 'update', b, a);
    END IF;
  END IF;
  RETURN NULL;
END $$;

CREATE FUNCTION sf_log.attach(p_design uuid) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN SELECT tab FROM sf_log.versioned() LOOP
    EXECUTE format('CREATE TRIGGER logged AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION sf_log.record()', r.tab);
    n := n + 1;
  END LOOP;
  INSERT INTO cortex.branches (design, name, head, current) VALUES (p_design, 'main', NULL, true);
  RETURN n;
END $$;

CREATE FUNCTION sf_log.current() RETURNS cortex.branches LANGUAGE sql STABLE AS $$
  SELECT * FROM cortex.branches WHERE current
$$;

CREATE FUNCTION sf_log.begin_turn(p_summary text, p_who text DEFAULT 'lab') RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE b cortex.branches := sf_log.current(); t uuid; op uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM cortex.turns WHERE state = 'open') THEN RAISE EXCEPTION 'a turn is still open'; END IF;
  INSERT INTO cortex.turns (parent, branch, by, who, summary, state, started_at)
    VALUES (b.head, b.id, 'person', p_who, p_summary, 'open', clock_timestamp()) RETURNING id INTO t;
  INSERT INTO cortex.operations (turn, kind, summary, at) VALUES (t, 'edit', p_summary, clock_timestamp()) RETURNING id INTO op;
  PERFORM set_config('sf.operation', op::text, true);
  RETURN t;
END $$;

CREATE FUNCTION sf_log.end_turn() RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE t cortex.turns;
BEGIN
  SELECT * INTO t FROM cortex.turns WHERE state = 'open';
  UPDATE cortex.turns SET state = 'accepted', ended_at = clock_timestamp(), decided_at = clock_timestamp(), decided_by = t.who WHERE id = t.id;
  UPDATE cortex.branches SET head = t.id WHERE id = t.branch;
  PERFORM set_config('sf.operation', '', true);
  RETURN t.id;
END $$;

CREATE FUNCTION sf_log.apply(c cortex.row_changes, backward boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE act text := c.action; v jsonb; sets text;
BEGIN
  IF backward THEN act := CASE c.action WHEN 'insert' THEN 'delete' WHEN 'delete' THEN 'insert' ELSE 'update' END; END IF;
  v := CASE WHEN backward THEN c.before ELSE c.after END;
  IF act = 'insert' THEN
    EXECUTE format('INSERT INTO %s SELECT * FROM jsonb_populate_record(NULL::%s, $1)', c.table_name, c.table_name) USING v;
  ELSIF act = 'delete' THEN
    EXECUTE format('DELETE FROM %s WHERE id = $1', c.table_name) USING c.row_id;
  ELSE
    SELECT string_agg(format('%I = r.%I', k, k), ', ') INTO sets FROM jsonb_object_keys(v) k;
    EXECUTE format('UPDATE %s t SET %s FROM jsonb_populate_record(NULL::%s, $1) r WHERE t.id = $2', c.table_name, sets, c.table_name) USING v, c.row_id;
  END IF;
END $$;

CREATE FUNCTION sf_log.ancestry(p_turn uuid) RETURNS TABLE (turn uuid, depth integer) LANGUAGE sql STABLE AS $$
  WITH RECURSIVE up AS (SELECT p_turn AS turn, 0 AS depth WHERE p_turn IS NOT NULL UNION ALL
    SELECT t.parent, up.depth + 1 FROM up JOIN cortex.turns t ON t.id = up.turn WHERE t.parent IS NOT NULL)
  SELECT turn, depth FROM up
$$;

-- the changes of the turns from p_from back to (not including) p_until, as the log holds them
CREATE FUNCTION sf_log.changes_between(p_from uuid, p_until uuid) RETURNS SETOF cortex.row_changes LANGUAGE sql STABLE AS $$
  SELECT c.* FROM cortex.row_changes c JOIN cortex.operations o ON o.id = c.operation
  WHERE o.turn IN (SELECT turn FROM sf_log.ancestry(p_from)
                   WHERE depth < coalesce((SELECT depth FROM sf_log.ancestry(p_from) WHERE turn = p_until), 1000000000))
$$;

-- the design moved from its branch's newest turn to any turn: back to their common turn, then forward
CREATE FUNCTION sf_log.move_to(p_to uuid) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE here uuid := (sf_log.current()).head; common uuid; c cortex.row_changes; n integer := 0;
BEGIN
  IF here IS NOT DISTINCT FROM p_to THEN RETURN 0; END IF;
  SELECT a.turn INTO common FROM sf_log.ancestry(here) a JOIN sf_log.ancestry(p_to) b ON a.turn = b.turn ORDER BY a.depth LIMIT 1;
  PERFORM set_config('sf.replaying', 'on', true);
  SET CONSTRAINTS ALL DEFERRED;
  FOR c IN SELECT * FROM sf_log.changes_between(here, common) ORDER BY id DESC LOOP
    PERFORM sf_log.apply(c, true); n := n + 1;
  END LOOP;
  FOR c IN SELECT * FROM sf_log.changes_between(p_to, common) ORDER BY id LOOP
    PERFORM sf_log.apply(c, false); n := n + 1;
  END LOOP;
  PERFORM set_config('sf.replaying', 'off', true);
  RETURN n;
END $$;

CREATE FUNCTION sf_log.switch(p_branch text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE b cortex.branches; n integer;
BEGIN
  SELECT * INTO b FROM cortex.branches WHERE name = p_branch;
  IF b.id IS NULL THEN RAISE EXCEPTION 'no branch %', p_branch; END IF;
  n := sf_log.move_to(b.head);
  UPDATE cortex.branches SET current = (id = b.id) WHERE design = b.design;
  RETURN n;
END $$;

CREATE FUNCTION sf_log.branch(p_name text, p_from text DEFAULT NULL) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE t uuid := coalesce((SELECT turn FROM cortex.savepoints WHERE name = p_from), (sf_log.current()).head); n integer;
BEGIN
  n := sf_log.move_to(t);
  INSERT INTO cortex.branches (design, name, head, current) VALUES ((sf_log.current()).design, p_name, t, false);  -- it forks from t
  UPDATE cortex.branches SET current = (name = p_name) WHERE design = (SELECT design FROM cortex.branches WHERE name = p_name);
  RETURN n;
END $$;

CREATE FUNCTION sf_log.state_hash() RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record; acc text := '';
BEGIN
  FOR r IN SELECT tab FROM sf_log.versioned() LOOP
    EXECUTE format('SELECT $1 || coalesce(md5(string_agg(to_jsonb(t)::text, '','' ORDER BY t.id)), '''') FROM %s t', r.tab) INTO acc USING acc;
  END LOOP;
  RETURN encode(sha256(convert_to(acc, 'UTF8')), 'hex');
END $$;

CREATE FUNCTION sf_log.savepoint(p_name text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE t uuid := (sf_log.current()).head;
BEGIN
  -- the name is unique per design, deferrable, so ON CONFLICT cannot take it: move the savepoint, or make it
  UPDATE cortex.savepoints SET turn = t, made_at = clock_timestamp() WHERE design = (sf_log.current()).design AND name = p_name;
  IF NOT FOUND THEN
    INSERT INTO cortex.savepoints (design, name, turn, made_by, made_at) VALUES ((sf_log.current()).design, p_name, t, 'lab', clock_timestamp());
  END IF;
  RETURN t;
END $$;

CREATE FUNCTION sf_log.lock_version(p_message text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE h text := sf_log.state_hash();
BEGIN
  INSERT INTO cortex.locked_versions (design, number, turn, hash, message, locked_by, locked_at)
    VALUES ((sf_log.current()).design, coalesce((SELECT max(number) FROM cortex.locked_versions WHERE design = (sf_log.current()).design), 0) + 1,
            (sf_log.current()).head, h, p_message, 'lab', clock_timestamp());
  RETURN h;
END $$;

-- back to a savepoint, as a new turn of inverses: the history stays, the branch goes on from it
CREATE FUNCTION sf_log.restore(p_name text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE target uuid := (SELECT turn FROM cortex.savepoints WHERE name = p_name); here uuid := (sf_log.current()).head; c cortex.row_changes;
BEGIN
  IF target IS NULL THEN RAISE EXCEPTION 'no savepoint %', p_name; END IF;
  PERFORM sf_log.begin_turn('restore ' || p_name);
  SET CONSTRAINTS ALL DEFERRED;
  FOR c IN SELECT * FROM sf_log.changes_between(here, target) ORDER BY id DESC LOOP
    PERFORM sf_log.apply(c, true);
  END LOOP;
  RETURN sf_log.end_turn();
END $$;

CREATE FUNCTION sf_log.compare(p_from text, p_to text) RETURNS TABLE (table_name text, row_id bigint, what text) LANGUAGE sql STABLE AS $$
  SELECT c.table_name, c.row_id, CASE WHEN bool_or(c.action = 'insert') AND bool_or(c.action = 'delete') THEN 'made and removed'
    WHEN bool_or(c.action = 'insert') THEN 'added' WHEN bool_or(c.action = 'delete') THEN 'removed' ELSE 'changed' END
  FROM sf_log.changes_between((SELECT turn FROM cortex.savepoints WHERE name = p_to), (SELECT turn FROM cortex.savepoints WHERE name = p_from)) c
  GROUP BY c.table_name, c.row_id ORDER BY 1, 2
$$;
