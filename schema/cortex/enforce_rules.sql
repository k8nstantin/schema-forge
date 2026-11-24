-- enforce_rules: how a rule's view becomes something the database itself refuses to commit. Owner: cortex.
-- A rule is a view named broken_<rule> in its owner's namespace, listing the rows that break it (one file per rule, in
-- the owner's rules folder). cortex.enforce_rules(owner) reads which tables each of the owner's rule views reads, and
-- puts two triggers on every one of them:
--   rule:<owner>.<rule>        a constraint trigger, DEFERRABLE INITIALLY DEFERRED, for each row inserted, updated or
--                              deleted: at commit it reads the view and refuses the commit (check_violation) naming the
--                              rule and the first rows breaking it; it reads the view once per commit, not once per row
--   rule:<owner>.<rule>:again  a statement trigger: any later write to the table marks the rule to be read again
-- No list of tables is written by hand: the view says what it reads, so a rule cannot miss a table it depends on.
-- Migrations run cortex.enforce_rules after their rules; running it again replaces the triggers.

CREATE FUNCTION cortex.rule_flag(rule text) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT 'schema_forge.rule_' || md5(rule) $$;

COMMENT ON FUNCTION cortex.rule_flag(text) IS 'the transaction setting that says a rule was read and held since the last write to its tables';

CREATE FUNCTION cortex.rule_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  rule   text := TG_ARGV[0];
  flag   text := cortex.rule_flag(TG_ARGV[0]);
  broken text;
BEGIN
  IF current_setting(flag, true) = 'held' THEN
    RETURN NULL;
  END IF;
  EXECUTE format('SELECT string_agg(id, '', '') FROM (SELECT id FROM %s ORDER BY id LIMIT 5) b', rule) INTO broken;
  IF broken IS NOT NULL THEN
    RAISE EXCEPTION 'rule % is broken by %', rule, broken
      USING ERRCODE = 'check_violation', HINT = format('SELECT * FROM %s lists every row breaking it', rule);
  END IF;
  PERFORM set_config(flag, 'held', true);
  RETURN NULL;
END $$;

COMMENT ON FUNCTION cortex.rule_check() IS 'at commit, refuses the commit when the rule view named by the trigger lists a row; once held, it is not read again until a write marks it';

CREATE FUNCTION cortex.rule_again() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config(cortex.rule_flag(TG_ARGV[0]), 'again', true);
  RETURN NULL;
END $$;

COMMENT ON FUNCTION cortex.rule_again() IS 'after a write to a table a rule reads, marks the rule to be read again at commit';

CREATE FUNCTION cortex.enforce_rules(owner text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  v     record;
  t     record;
  name  text;
  count integer := 0;
BEGIN
  FOR v IN
    SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = owner AND c.relkind = 'v' AND c.relname LIKE 'broken\_%' ORDER BY c.relname
  LOOP
    name := 'rule:' || owner || '.' || substr(v.relname, 8);
    IF length(name || ':again') > 63 THEN
      RAISE EXCEPTION 'rule name % is too long for its triggers (63 bytes with :again)', name;
    END IF;
    FOR t IN
      SELECT DISTINCT d.refobjid::regclass AS tab
      FROM pg_rewrite r JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
      JOIN pg_class rc ON rc.oid = d.refobjid
      WHERE r.ev_class = v.oid AND d.refclassid = 'pg_class'::regclass AND rc.relkind IN ('r', 'p')
    LOOP
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', name, t.tab);
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', name || ':again', t.tab);
      EXECUTE format('CREATE CONSTRAINT TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s DEFERRABLE INITIALLY DEFERRED '
                     'FOR EACH ROW EXECUTE FUNCTION cortex.rule_check(%L)', name, t.tab, owner || '.' || v.relname);
      EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s '
                     'FOR EACH STATEMENT EXECUTE FUNCTION cortex.rule_again(%L)', name || ':again', t.tab, owner || '.' || v.relname);
      count := count + 1;
    END LOOP;
  END LOOP;
  RETURN count;
END $$;

COMMENT ON FUNCTION cortex.enforce_rules(text) IS 'puts the triggers of every rule view of a namespace on each table the view reads; returns how many tables it guarded';
