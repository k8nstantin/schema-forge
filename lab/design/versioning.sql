-- The lab's versioning: every change to every table of the global schema and of the plugins' is logged by one trigger,
-- value by value, in a turn; turns form a tree; branches are named tips of it; savepoints name a turn, versions lock one
-- with a hash. Switch, open, restore and compare work on the log alone, so a plugin gets all of it by existing.

CREATE SCHEMA IF NOT EXISTS log;

CREATE TABLE log.turns (
  id       bigint      PRIMARY KEY GENERATED ALWAYS AS IDENTITY,  -- in the order made
  parent   bigint      REFERENCES log.turns (id),                -- the turn it follows; NULL for the first
  branch   text        NOT NULL,                                 -- the branch it was made on
  summary  text        NOT NULL,                                 -- what it does, in a line
  made_at  timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE log.changes (
  id        bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,  -- in the order they happened
  turn      bigint NOT NULL REFERENCES log.turns (id),
  tab       text   NOT NULL,                                   -- schema.table
  row_id    bigint NOT NULL,                                   -- the row's id
  op        text   NOT NULL CHECK (op IN ('insert', 'update', 'delete')),
  before    jsonb,                                             -- update: only the columns that changed; delete: the whole row
  after     jsonb                                              -- update: only the columns that changed; insert: the whole row
);
CREATE INDEX changes_turn ON log.changes (turn, id);

CREATE TABLE log.branches (
  name  text   PRIMARY KEY,
  head  bigint NOT NULL REFERENCES log.turns (id)  -- its newest turn
);

CREATE TABLE log.savepoints (
  name      text        PRIMARY KEY,
  turn      bigint      NOT NULL REFERENCES log.turns (id),
  locked    boolean     NOT NULL DEFAULT false,  -- a version: never moved, never deleted
  hash      text,                                -- a version's: the md5 of the whole state at its turn
  made_at   timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- The working state: which branch is checked out, which turn is open, and whether changes are being logged.
CREATE TABLE log.state (
  one      boolean PRIMARY KEY DEFAULT true CHECK (one),
  branch   text    NOT NULL,
  at_turn  bigint  REFERENCES log.turns (id),  -- the turn the tables now hold
  open     bigint  REFERENCES log.turns (id)   -- the turn being made; NULL between turns
);

-- Every versioned table: the global schema's and every plugin's. Each has a bigint id.
CREATE OR REPLACE FUNCTION log.versioned() RETURNS TABLE (tab text) LANGUAGE sql STABLE AS $$
  SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND (n.nspname = 'core' OR n.nspname LIKE 'engine\_%') ORDER BY 1
$$;

CREATE OR REPLACE FUNCTION log.record() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  t bigint := (SELECT open FROM log.state);
  o jsonb; n jsonb; b jsonb := '{}'; a jsonb := '{}'; k text;
BEGIN
  IF current_setting('log.replaying', true) = 'on' THEN RETURN NULL; END IF;
  IF t IS NULL THEN RAISE EXCEPTION 'a change outside a turn: begin one with log.begin_turn'; END IF;
  IF TG_OP = 'INSERT' THEN
    INSERT INTO log.changes (turn, tab, row_id, op, after) VALUES (t, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, NEW.id, 'insert', to_jsonb(NEW));
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO log.changes (turn, tab, row_id, op, before) VALUES (t, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, OLD.id, 'delete', to_jsonb(OLD));
  ELSE
    o := to_jsonb(OLD); n := to_jsonb(NEW);
    FOR k IN SELECT jsonb_object_keys(n) LOOP
      IF o -> k IS DISTINCT FROM n -> k THEN b := b || jsonb_build_object(k, o -> k); a := a || jsonb_build_object(k, n -> k); END IF;
    END LOOP;
    IF a <> '{}' THEN
      INSERT INTO log.changes (turn, tab, row_id, op, before, after) VALUES (t, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, OLD.id, 'update', b, a);
    END IF;
  END IF;
  RETURN NULL;
END $$;

-- Puts the trigger on every versioned table; run after the schema's tables are made, and after a plugin adds one.
CREATE OR REPLACE FUNCTION log.attach() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN SELECT tab FROM log.versioned() LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS logged ON %s', r.tab);
    EXECUTE format('CREATE TRIGGER logged AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION log.record()', r.tab);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION log.init(p_branch text DEFAULT 'main') RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO log.state (branch) VALUES (p_branch) ON CONFLICT (one) DO NOTHING;
END $$;

-- A turn on the branch checked out, after the turn the tables hold.
CREATE OR REPLACE FUNCTION log.begin_turn(p_summary text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE s log.state; t bigint;
BEGIN
  SELECT * INTO s FROM log.state;
  IF s.open IS NOT NULL THEN RAISE EXCEPTION 'turn % is still open', s.open; END IF;
  INSERT INTO log.turns (parent, branch, summary) VALUES (s.at_turn, s.branch, p_summary) RETURNING id INTO t;
  UPDATE log.state SET open = t;
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION log.end_turn() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE s log.state;
BEGIN
  SELECT * INTO s FROM log.state;
  UPDATE log.state SET at_turn = s.open, open = NULL;
  INSERT INTO log.branches (name, head) VALUES (s.branch, s.open) ON CONFLICT (name) DO UPDATE SET head = EXCLUDED.head;
  RETURN s.open;
END $$;

-- One change applied forward or backward, its trigger silent (moving the working state is not a change).
CREATE OR REPLACE FUNCTION log.apply(c log.changes, backward boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE op text := c.op; v jsonb; sets text; cols text;
BEGIN
  IF backward THEN
    op := CASE c.op WHEN 'insert' THEN 'delete' WHEN 'delete' THEN 'insert' ELSE 'update' END;
  END IF;
  IF op = 'insert' THEN
    v := CASE WHEN backward THEN c.before ELSE c.after END;
    EXECUTE format('INSERT INTO %s SELECT * FROM jsonb_populate_record(NULL::%s, $1)', c.tab, c.tab) USING v;
  ELSIF op = 'delete' THEN
    EXECUTE format('DELETE FROM %s WHERE id = $1', c.tab) USING c.row_id;
  ELSE
    v := CASE WHEN backward THEN c.before ELSE c.after END;
    SELECT string_agg(format('%I = r.%I', k, k), ', '), string_agg(format('%I', k), ', ') INTO sets, cols FROM jsonb_object_keys(v) k;
    EXECUTE format('UPDATE %s t SET %s FROM jsonb_populate_record(NULL::%s, $1) r WHERE t.id = $2', c.tab, sets, c.tab) USING v, c.row_id;
  END IF;
END $$;

-- The turns from a turn up to the first (the turn itself first).
CREATE OR REPLACE FUNCTION log.ancestry(p_turn bigint) RETURNS TABLE (turn bigint, depth integer) LANGUAGE sql STABLE AS $$
  WITH RECURSIVE up AS (SELECT p_turn AS turn, 0 AS depth UNION ALL
    SELECT t.parent, up.depth + 1 FROM up JOIN log.turns t ON t.id = up.turn WHERE t.parent IS NOT NULL)
  SELECT turn, depth FROM up
$$;

-- Moves the tables from the turn they hold to p_to: back along the way to the turns both share, then forward.
CREATE OR REPLACE FUNCTION log.move_to(p_to bigint) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE s log.state; common bigint; c log.changes; n integer := 0;
BEGIN
  SELECT * INTO s FROM log.state;
  IF s.open IS NOT NULL THEN RAISE EXCEPTION 'turn % is still open', s.open; END IF;
  IF s.at_turn IS NOT DISTINCT FROM p_to THEN RETURN 0; END IF;
  SELECT a.turn INTO common FROM log.ancestry(s.at_turn) a JOIN log.ancestry(p_to) b ON a.turn = b.turn ORDER BY a.depth LIMIT 1;
  PERFORM set_config('log.replaying', 'on', true);
  SET CONSTRAINTS ALL DEFERRED;
  FOR c IN SELECT ch.* FROM log.changes ch WHERE ch.turn IN (SELECT turn FROM log.ancestry(s.at_turn) WHERE turn IS DISTINCT FROM common
           AND depth < coalesce((SELECT depth FROM log.ancestry(s.at_turn) WHERE turn = common), 1000000000)) ORDER BY ch.id DESC LOOP
    PERFORM log.apply(c, true); n := n + 1;
  END LOOP;
  FOR c IN SELECT ch.* FROM log.changes ch WHERE ch.turn IN (SELECT turn FROM log.ancestry(p_to) WHERE turn IS DISTINCT FROM common
           AND depth < coalesce((SELECT depth FROM log.ancestry(p_to) WHERE turn = common), 1000000000)) ORDER BY ch.id LOOP
    PERFORM log.apply(c, false); n := n + 1;
  END LOOP;
  PERFORM set_config('log.replaying', 'off', true);
  UPDATE log.state SET at_turn = p_to;
  RETURN n;
END $$;

-- Switches to a branch: the tables become its head.
CREATE OR REPLACE FUNCTION log.switch(p_branch text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE h bigint := (SELECT head FROM log.branches WHERE name = p_branch); n integer;
BEGIN
  IF h IS NULL THEN RAISE EXCEPTION 'no branch %', p_branch; END IF;
  n := log.move_to(h);
  UPDATE log.state SET branch = p_branch;
  RETURN n;
END $$;

-- A new branch from a savepoint (or the turn the tables hold), switched to.
CREATE OR REPLACE FUNCTION log.branch(p_name text, p_from text DEFAULT NULL) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE t bigint := coalesce((SELECT turn FROM log.savepoints WHERE name = p_from), (SELECT at_turn FROM log.state)); n integer;
BEGIN
  INSERT INTO log.branches (name, head) VALUES (p_name, t);
  n := log.move_to(t);
  UPDATE log.state SET branch = p_name;
  RETURN n;
END $$;

-- The whole state, as one hash: every versioned table's rows, sorted.
CREATE OR REPLACE FUNCTION log.state_hash() RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record; acc text := '';
BEGIN
  FOR r IN SELECT tab FROM log.versioned() LOOP
    EXECUTE format('SELECT $1 || coalesce(md5(string_agg(to_jsonb(t)::text, '','' ORDER BY t.id)), '''') FROM %s t', r.tab) INTO acc USING acc;
  END LOOP;
  RETURN md5(acc);
END $$;

CREATE OR REPLACE FUNCTION log.savepoint(p_name text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE t bigint := (SELECT at_turn FROM log.state);
BEGIN
  INSERT INTO log.savepoints (name, turn) VALUES (p_name, t) ON CONFLICT (name) DO UPDATE SET turn = EXCLUDED.turn WHERE NOT log.savepoints.locked;
  RETURN t;
END $$;

-- A version: a savepoint locked, with the hash of the state at it.
CREATE OR REPLACE FUNCTION log.lock_version(p_name text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE h text := log.state_hash();
BEGIN
  INSERT INTO log.savepoints (name, turn, locked, hash) VALUES (p_name, (SELECT at_turn FROM log.state), true, h);
  RETURN h;
END $$;

-- Restore: one new turn that makes the state the savepoint's again, history kept.
CREATE OR REPLACE FUNCTION log.restore(p_name text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE target bigint := (SELECT turn FROM log.savepoints WHERE name = p_name); here bigint; t bigint; c log.changes;
BEGIN
  IF target IS NULL THEN RAISE EXCEPTION 'no savepoint %', p_name; END IF;
  here := (SELECT at_turn FROM log.state);
  t := log.begin_turn('restore ' || p_name);
  SET CONSTRAINTS ALL DEFERRED;
  -- undo every change made since the savepoint on this line, newest first, each undo itself logged in turn t
  FOR c IN SELECT ch.* FROM log.changes ch WHERE ch.turn IN (SELECT turn FROM log.ancestry(here)
           WHERE depth < (SELECT depth FROM log.ancestry(here) WHERE turn = target)) AND ch.turn <> t ORDER BY ch.id DESC LOOP
    PERFORM log.apply(c, true);
  END LOOP;
  RETURN log.end_turn();
END $$;

-- What changed between two savepoints (or turns on one line): each row's first state and last.
CREATE OR REPLACE FUNCTION log.compare(p_from text, p_to text) RETURNS TABLE (tab text, row_id bigint, what text) LANGUAGE sql STABLE AS $$
  WITH a AS (SELECT turn FROM log.savepoints WHERE name = p_from), b AS (SELECT turn FROM log.savepoints WHERE name = p_to),
  span AS (SELECT x.turn FROM log.ancestry((SELECT turn FROM b)) x
           WHERE x.depth < (SELECT depth FROM log.ancestry((SELECT turn FROM b)) WHERE turn = (SELECT turn FROM a)))
  SELECT c.tab, c.row_id, CASE WHEN bool_or(c.op = 'insert') AND bool_or(c.op = 'delete') THEN 'made and removed'
    WHEN bool_or(c.op = 'insert') THEN 'added' WHEN bool_or(c.op = 'delete') THEN 'removed' ELSE 'changed' END
  FROM log.changes c WHERE c.turn IN (SELECT turn FROM span) GROUP BY c.tab, c.row_id ORDER BY 1, 2
$$;
