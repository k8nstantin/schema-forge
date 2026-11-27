-- cortex.check_object: what every engine refuses the same way, as an object is written: a kind its design's version
-- does not have (cortex.object_kinds since and until, compared by the versions' order) and a kind its design's flavor
-- refuses (cortex.engine_flavors refuses.kinds). What only one engine refuses is its plugin's check.

CREATE FUNCTION cortex.check_object() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cortex AS $$
DECLARE
  bad record;
BEGIN
  SELECT d.engine_version, d.flavor, k.since, k."until", f.refuses INTO bad
    FROM cortex.designs d
    JOIN cortex.object_kinds k ON k.engine = d.engine AND k.kind = NEW.kind
    JOIN cortex.engine_versions v ON v.engine = d.engine AND v.version = d.engine_version
    JOIN cortex.engine_flavors f ON f.engine = d.engine AND f.flavor = d.flavor
    LEFT JOIN cortex.engine_versions s ON s.engine = d.engine AND s.version = k.since
    LEFT JOIN cortex.engine_versions u ON u.engine = d.engine AND u.version = k."until"
   WHERE d.id = NEW.design
     AND (v.position < s.position OR v.position > u.position OR coalesce(f.refuses -> 'kinds', '[]') ? NEW.kind);
  IF FOUND THEN
    IF bad.refuses -> 'kinds' ? NEW.kind THEN
      RAISE EXCEPTION '% refuses a % (%)', bad.flavor, NEW.kind, NEW.name USING ERRCODE = 'check_violation';
    END IF;
    RAISE EXCEPTION '% % has no % (from %, until %): %', NEW.engine, bad.engine_version, NEW.kind, coalesce(bad.since, 'the first'), coalesce(bad."until", 'the last'), NEW.name
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER check_object AFTER INSERT OR UPDATE OF kind ON cortex.objects
  DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cortex.check_object();

COMMENT ON FUNCTION cortex.check_object() IS 'refuses an object of a kind its design''s version lacks or its design''s flavor refuses';
