-- cortex.check_design: a design is made only for a version its flavor runs (cortex.engine_flavors refuses.versions):
-- Amazon Aurora MySQL 3 is MySQL 8.0, so an Aurora design of 5.7, 8.4 or 9.7 is refused. The same for every engine.

CREATE FUNCTION cortex.check_design() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cortex AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM cortex.engine_flavors f WHERE f.engine = NEW.engine AND f.flavor = NEW.flavor
              AND coalesce(f.refuses -> 'versions', '[]') ? NEW.engine_version) THEN
    RAISE EXCEPTION '% does not run % %', (SELECT name FROM cortex.engine_flavors WHERE engine = NEW.engine AND flavor = NEW.flavor), NEW.engine, NEW.engine_version
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER check_design AFTER INSERT OR UPDATE OF engine_version, flavor ON cortex.designs
  DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cortex.check_design();

COMMENT ON FUNCTION cortex.check_design() IS 'refuses a design of a version its flavor does not run';
