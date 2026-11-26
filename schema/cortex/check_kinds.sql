-- check_kinds: the guard of object kinds and of a design's target (decision declared-options). Owner: cortex.
-- As objects are written, each one's kind must be one its design's engine declares (cortex.object_kinds) in the design's
-- version, one its design's flavor has (a kind one flavor alone has is taken on that flavor's designs only; one the
-- flavor lacks, cortex.flavor_limits with severity refused, is refused), and it must sit in a namespace exactly when its
-- kind's objects live in one: a MySQL tablespace sits in none. As a design is made or retargeted, its flavor must offer its version.
-- Anything else is refused, naming the kind and why, whoever wrote it. The objects a statement wrote are checked
-- together, once, after it (a transition table): an import of thousands costs one query, not one a row.

CREATE FUNCTION cortex.check_kinds() RETURNS trigger LANGUAGE plpgsql STABLE AS $$
DECLARE
  bad record;
BEGIN
  SELECT n.kind, n.namespace, d.engine, d.engine_version, d.flavor, k.id AS kid, k.scope, k.flavor AS kflavor, l.about AS lacks,
         (k.since IS NOT NULL AND v.position < (SELECT s.position FROM cortex.engine_versions s WHERE s.id = k.since)
          OR k."until" IS NOT NULL AND v.position > (SELECT u.position FROM cortex.engine_versions u WHERE u.id = k."until")) AS out_of_version
    INTO bad
    FROM new_objects n
    JOIN cortex.designs d ON d.id = n.design
    LEFT JOIN cortex.object_kinds k ON k.engine = d.engine AND k.kind = n.kind
    LEFT JOIN cortex.engine_versions v ON v.engine = d.engine AND v.version = d.engine_version
    LEFT JOIN LATERAL (
      SELECT l.about FROM cortex.flavor_limits l
       WHERE l.flavor = d.flavor AND l.severity = 'refused' AND l.what = 'kind' AND l.kind = k.id
         AND (l.since IS NULL OR v.position >= (SELECT s.position FROM cortex.engine_versions s WHERE s.id = l.since))
         AND (l."until" IS NULL OR v.position <= (SELECT u.position FROM cortex.engine_versions u WHERE u.id = l."until"))
       LIMIT 1) l ON true
   WHERE k.id IS NULL
      OR k.since IS NOT NULL AND v.position < (SELECT s.position FROM cortex.engine_versions s WHERE s.id = k.since)
      OR k."until" IS NOT NULL AND v.position > (SELECT u.position FROM cortex.engine_versions u WHERE u.id = k."until")
      OR k.flavor IS NOT NULL AND k.flavor IS DISTINCT FROM d.flavor
      OR l.about IS NOT NULL
      OR (k.scope = 'namespace') = (n.namespace IS NULL)
   LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF bad.kid IS NULL THEN
    RAISE EXCEPTION 'kind % is not declared for %', bad.kind, bad.engine USING ERRCODE = 'check_violation';
  ELSIF bad.out_of_version THEN
    RAISE EXCEPTION 'a % is not in % %', bad.kind, bad.engine, bad.engine_version USING ERRCODE = 'check_violation';
  ELSIF bad.kflavor IS NOT NULL AND bad.kflavor IS DISTINCT FROM bad.flavor THEN
    RAISE EXCEPTION 'a % is %''s alone', bad.kind, bad.kflavor USING ERRCODE = 'check_violation';
  ELSIF bad.lacks IS NOT NULL THEN
    RAISE EXCEPTION '% has no %: %', bad.flavor, bad.kind, bad.lacks USING ERRCODE = 'check_violation';
  ELSIF bad.scope = 'namespace' THEN
    RAISE EXCEPTION 'a % lives in a namespace', bad.kind USING ERRCODE = 'check_violation';
  ELSE
    RAISE EXCEPTION 'a % lives in the %, in no namespace', bad.kind, bad.scope USING ERRCODE = 'check_violation';
  END IF;
END $$;

CREATE TRIGGER kinds AFTER INSERT ON cortex.objects
  REFERENCING NEW TABLE AS new_objects FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_kinds();
CREATE TRIGGER kinds_changed AFTER UPDATE ON cortex.objects
  REFERENCING NEW TABLE AS new_objects FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_kinds();

CREATE FUNCTION cortex.check_designs() RETURNS trigger LANGUAGE plpgsql STABLE AS $$
DECLARE
  lim cortex.flavor_limits;
BEGIN
  IF NEW.flavor IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO lim FROM cortex.flavor_limits
   WHERE flavor = NEW.flavor AND what = 'version' AND version = NEW.engine || '/' || NEW.engine_version AND severity = 'refused' LIMIT 1;
  IF lim.id IS NOT NULL THEN
    RAISE EXCEPTION '% does not offer % %: %', NEW.flavor, NEW.engine, NEW.engine_version, lim.about USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER target BEFORE INSERT OR UPDATE OF engine_version, flavor ON cortex.designs
  FOR EACH ROW EXECUTE FUNCTION cortex.check_designs();
