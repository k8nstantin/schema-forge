-- check_options: the guard of declared options (decision declared-options). Owner: cortex.
-- As each row of a part of the model is written, every key of its options must be an option its design's engine declares
-- for that part (cortex.option_declarations), its value of the declared type, one of its declared values when it has
-- some, not null when it may not be, and in the design's version when the option has a first or a last one. Anything
-- else is refused, naming the option and why, whoever wrote it.

CREATE FUNCTION cortex.check_options() RETURNS trigger LANGUAGE plpgsql STABLE AS $$
DECLARE
  d cortex.designs;
  o record;
  dec cortex.option_declarations;
  at numeric;
BEGIN
  IF NEW.options = '{}'::jsonb THEN RETURN NEW; END IF;
  IF jsonb_typeof(NEW.options) <> 'object' THEN
    RAISE EXCEPTION 'options must be an object, not %', jsonb_typeof(NEW.options) USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO d FROM cortex.designs WHERE id = NEW.design;
  SELECT position INTO at FROM cortex.engine_versions WHERE engine = d.engine AND version = d.engine_version;
  FOR o IN SELECT key, value FROM jsonb_each(NEW.options) LOOP
    SELECT * INTO dec FROM cortex.option_declarations WHERE engine = d.engine AND part = TG_TABLE_NAME AND name = o.key;
    IF dec.id IS NULL THEN
      RAISE EXCEPTION 'option % is not declared for % %', o.key, d.engine, TG_TABLE_NAME USING ERRCODE = 'check_violation';
    END IF;
    IF jsonb_typeof(o.value) = 'null' THEN
      IF NOT dec.nullable THEN
        RAISE EXCEPTION 'option % may not be null', o.key USING ERRCODE = 'check_violation';
      END IF;
      CONTINUE;
    END IF;
    IF dec.value_type = 'json' AND jsonb_typeof(o.value) NOT IN ('array', 'object')
       OR dec.value_type <> 'json' AND jsonb_typeof(o.value) <> dec.value_type THEN
      RAISE EXCEPTION 'option % is a %, not a %', o.key, dec.value_type, jsonb_typeof(o.value) USING ERRCODE = 'check_violation';
    END IF;
    IF dec.choices IS NOT NULL AND NOT dec.choices @> jsonb_build_array(o.value) THEN
      RAISE EXCEPTION 'option % may be one of %, not %', o.key, dec.choices, o.value USING ERRCODE = 'check_violation';
    END IF;
    IF dec.since IS NOT NULL AND at < (SELECT position FROM cortex.engine_versions WHERE id = dec.since)
       OR dec."until" IS NOT NULL AND at > (SELECT position FROM cortex.engine_versions WHERE id = dec."until") THEN
      RAISE EXCEPTION 'option % is not in % %', o.key, d.engine, d.engine_version USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.namespaces
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.objects
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.columns
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.column_identities
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.constraints
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.constraint_columns
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.domains
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.enum_values
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.indexes
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.index_parts
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.partitionings
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.partitions
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.routines
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.routine_parameters
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.sequences
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.sort_fields
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.triggers
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options BEFORE INSERT OR UPDATE OF options ON cortex.views
  FOR EACH ROW EXECUTE FUNCTION cortex.check_options();
