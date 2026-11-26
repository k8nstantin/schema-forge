-- check_kinds: the guard of object kinds (decision declared-options). Owner: cortex.
-- As an object is written, its kind must be one its design's engine declares (cortex.object_kinds), and it must sit in a
-- namespace exactly when its kind's objects live in one: a MySQL tablespace sits in none. Anything else is refused,
-- naming the kind and why, whoever wrote it.

CREATE FUNCTION cortex.check_kinds() RETURNS trigger LANGUAGE plpgsql STABLE AS $$
DECLARE
  k cortex.object_kinds;
  e text;
BEGIN
  SELECT engine INTO e FROM cortex.designs WHERE id = NEW.design;
  SELECT * INTO k FROM cortex.object_kinds WHERE engine = e AND kind = NEW.kind;
  IF k.id IS NULL THEN
    RAISE EXCEPTION 'kind % is not declared for %', NEW.kind, e USING ERRCODE = 'check_violation';
  END IF;
  IF k.scope = 'server' AND NEW.namespace IS NOT NULL THEN
    RAISE EXCEPTION 'a % lives in the server, in no namespace', NEW.kind USING ERRCODE = 'check_violation';
  END IF;
  IF k.scope = 'namespace' AND NEW.namespace IS NULL THEN
    RAISE EXCEPTION 'a % lives in a namespace', NEW.kind USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER kinds BEFORE INSERT OR UPDATE OF kind, namespace ON cortex.objects
  FOR EACH ROW EXECUTE FUNCTION cortex.check_kinds();
