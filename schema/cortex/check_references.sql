-- check_references: the guard of what references point at (decision reference-kinds). Owner: cortex.
-- A foreign key holds that the row a reference points at exists; this guard holds that it is the right one. As rows are
-- written, every reference cortex.reference_kinds declares for the design's engine must point at an object of a kind it
-- names (a grant's grantee a role or an account, a trigger's parent a table, a foreign table's server a foreign server);
-- a reference no rule of the design's engine covers may not be set at all (closed); every privilege granted must be
-- one cortex.privilege_declarations declares for the engine, at that level, in the
-- design's version; and what must belong together does: an index's parts are columns of its table, a key's columns of its
-- table and its referenced columns of the table it refers to, a statistics object's columns of its table, a published
-- table's columns of that table, a trigger's UPDATE OF columns of its table. The rows a statement wrote are checked
-- together, once, after it (a transition table). cortex.guard_references(owner) puts the guard on every table of an
-- owner that holds a design's rows; the loader runs it with cortex.enforce_rules, after the owner's tables.

CREATE FUNCTION cortex.check_references() RETURNS trigger LANGUAGE plpgsql STABLE AS $$
DECLARE
  bad record;
  this_part text := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
BEGIN
  -- the kind of every object a reference points at
  SELECT rk.field, o.kind, o.name, rk.kinds, rk.about INTO bad
    FROM new_rows r
    JOIN cortex.designs d ON d.id = (to_jsonb(r) ->> 'design')::uuid
    JOIN cortex.reference_kinds rk ON rk.engine = d.engine AND rk.part = this_part
     AND (rk.condition_field IS NULL
          OR coalesce(to_jsonb(r) ->> rk.condition_field, to_jsonb(r) -> 'options' ->> rk.condition_field, '') = rk.condition_value)
    JOIN cortex.objects o ON o.id = (to_jsonb(r) ->> rk.field)::uuid
   WHERE NOT rk.kinds ? o.kind
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION '% may refer to % only (%), not to the % %', bad.field, bad.kinds, bad.about, bad.kind, bad.name USING ERRCODE = 'check_violation';
  END IF;
  -- closed: a reference some engine declares rules for may be set only where the design's engine has a rule that applies
  -- (MySQL has no sequences: an AUTO_INCREMENT's identity draws on none; a dependency's role must be one declared)
  SELECT f.field, d.engine, coalesce(to_jsonb(r) -> 'options' ->> 'as', to_jsonb(r) ->> 'kind', '') AS how INTO bad
    FROM new_rows r
    JOIN cortex.designs d ON d.id = (to_jsonb(r) ->> 'design')::uuid
    CROSS JOIN (SELECT DISTINCT rk.field FROM cortex.reference_kinds rk WHERE rk.part = this_part) f
   WHERE to_jsonb(r) ->> f.field IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM cortex.reference_kinds rk WHERE rk.engine = d.engine AND rk.part = this_part AND rk.field = f.field
                       AND (rk.condition_field IS NULL
                            OR coalesce(to_jsonb(r) ->> rk.condition_field, to_jsonb(r) -> 'options' ->> rk.condition_field, '') = rk.condition_value))
     -- an object's parent is declared for the kinds that have one; an object of another kind has none
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION '% declares no % of % here (%)', bad.engine, bad.field, this_part, nullif(bad.how, '') USING ERRCODE = 'check_violation';
  END IF;
  -- a privilege the engine has, at the level it is granted, in the design's version
  IF this_part IN ('cortex.privileges', 'engine_postgresql.default_privileges') THEN
    SELECT x.privilege, x.level, d.engine, d.engine_version, p.id AS declared INTO bad
      FROM (SELECT to_jsonb(r) ->> 'privilege' AS privilege, (to_jsonb(r) ->> 'design')::uuid AS design,
                   CASE WHEN this_part = 'engine_postgresql.default_privileges' THEN 'object'
                        WHEN to_jsonb(r) ->> 'column' IS NOT NULL THEN 'column' WHEN to_jsonb(r) ->> 'object' IS NOT NULL THEN 'object'
                        WHEN to_jsonb(r) ->> 'namespace' IS NOT NULL THEN 'namespace' ELSE 'server' END AS level
              FROM new_rows r) x
      JOIN cortex.designs d ON d.id = x.design
      JOIN cortex.engine_versions v ON v.engine = d.engine AND v.version = d.engine_version
      LEFT JOIN LATERAL (SELECT * FROM cortex.privilege_declarations p WHERE p.engine = d.engine
                           AND (p.privilege = x.privilege OR p.pattern AND x.privilege ~ p.privilege) ORDER BY p.pattern LIMIT 1) p ON true
     WHERE p.id IS NULL OR NOT p.levels ? x.level
        OR p.since IS NOT NULL AND v.position < (SELECT s.position FROM cortex.engine_versions s WHERE s.id = p.since)
        OR p."until" IS NOT NULL AND v.position > (SELECT u.position FROM cortex.engine_versions u WHERE u.id = p."until")
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION '% % has no privilege % at the % level', bad.engine, bad.engine_version, bad.privilege, bad.level USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  -- what must belong to the same table
  IF this_part = 'cortex.index_parts' THEN
    SELECT i.name, c.name AS col INTO bad FROM new_rows r JOIN cortex.indexes i ON i.id = r.index JOIN cortex.columns c ON c.id = r."column"
     WHERE c.object <> i.object LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'index % has a part on %, a column of another table', bad.name, bad.col USING ERRCODE = 'check_violation'; END IF;
  ELSIF this_part = 'cortex.constraint_columns' THEN
    SELECT k.name, c.name AS col INTO bad FROM new_rows r JOIN cortex.constraints k ON k.id = r."constraint"
      LEFT JOIN cortex.columns c ON c.id = r."column" LEFT JOIN cortex.columns t ON t.id = r.to_column
     WHERE c.object <> k.object OR t.object <> k.to_object OR (r.to_column IS NOT NULL AND k.to_object IS NULL) LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'key % names a column not of its table, or not of the table it refers to (%)', bad.name, bad.col USING ERRCODE = 'check_violation'; END IF;
  ELSIF this_part = 'engine_postgresql.statistics_parts' THEN
    SELECT o.name, c.name AS col INTO bad FROM new_rows r JOIN cortex.objects o ON o.id = r.statistics JOIN cortex.columns c ON c.id = r."column"
     WHERE NOT EXISTS (SELECT 1 FROM cortex.dependencies d WHERE d.object = r.statistics AND d.uses = c.object AND d.options ->> 'as' = 'table') LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'statistics % counts over %, a column of another table', bad.name, bad.col USING ERRCODE = 'check_violation'; END IF;
  ELSIF this_part = 'engine_postgresql.publication_table_columns' THEN
    SELECT c.name AS col INTO bad FROM new_rows r JOIN engine_postgresql.publication_tables t ON t.id = r.publication_table JOIN cortex.columns c ON c.id = r."column"
     WHERE t."table" IS DISTINCT FROM c.object LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'a published table lists %, a column of another table', bad.col USING ERRCODE = 'check_violation'; END IF;
  ELSIF this_part = 'engine_postgresql.trigger_columns' THEN
    SELECT o.name, c.name AS col INTO bad FROM new_rows r JOIN cortex.objects o ON o.id = r.trigger JOIN cortex.columns c ON c.id = r."column"
     WHERE c.object IS DISTINCT FROM o.parent LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'trigger % fires on %, a column of another table', bad.name, bad.col USING ERRCODE = 'check_violation'; END IF;
  END IF;
  RETURN NULL;
END $$;

CREATE FUNCTION cortex.guard_references(owner text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  t record;
  n integer := 0;
BEGIN
  FOR t IN SELECT c.oid::regclass::text AS tab FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
            WHERE s.nspname = owner AND c.relkind = 'r'
              AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'design' AND NOT a.attisdropped)
              AND c.relname <> 'designs' LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS refs ON %s; DROP TRIGGER IF EXISTS refs_changed ON %s', t.tab, t.tab);
    EXECUTE format('CREATE TRIGGER refs AFTER INSERT ON %s REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_references()', t.tab);
    EXECUTE format('CREATE TRIGGER refs_changed AFTER UPDATE ON %s REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_references()', t.tab);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

COMMENT ON FUNCTION cortex.check_references() IS 'refuses a reference to an object of a kind its engine does not declare for it, a privilege its engine does not have there, and parts of one thing that name another table''s columns';
COMMENT ON FUNCTION cortex.guard_references(text) IS 'puts the guard check_references on every table of an owner''s namespace that holds a design''s rows';
