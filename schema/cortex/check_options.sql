-- check_options: the guard of declared options (decision declared-options). Owner: cortex.
-- As rows of a part of the model are written, every key of each one's options must be an option its design's engine
-- declares for that part (cortex.option_declarations), its value of the declared type, one of its declared values when
-- it has some, not null when it may not be, and in the design's version when the option has a first or a last one. An
-- option one flavor alone has is taken on that flavor's designs only, and what the design's flavor lacks
-- (cortex.flavor_limits, severity refused), the option or that one value of it, is refused. Anything else is refused,
-- naming the option and why, whoever wrote it. The rows a statement wrote are checked together, once, after it (a
-- transition table): an import of thousands costs one query a part, not one a row.

CREATE FUNCTION cortex.check_options() RETURNS trigger LANGUAGE plpgsql STABLE AS $$
DECLARE
  bad record;
BEGIN
  SELECT jsonb_typeof(r.options) AS shape, x.key, x.value, d.engine, d.engine_version, d.flavor,
         dec.id AS did, dec.flavor AS dflavor, dec.nullable, dec.value_type, dec.choices,
         (dec.since IS NOT NULL AND v.position < (SELECT s.position FROM cortex.engine_versions s WHERE s.id = dec.since)
          OR dec."until" IS NOT NULL AND v.position > (SELECT u.position FROM cortex.engine_versions u WHERE u.id = dec."until")) AS out_of_version,
         l.about AS lacks
    INTO bad
    FROM new_rows r
    JOIN cortex.designs d ON d.id = r.design
    LEFT JOIN cortex.engine_versions v ON v.engine = d.engine AND v.version = d.engine_version
    LEFT JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(r.options) = 'object' THEN r.options END) x ON true
    LEFT JOIN cortex.option_declarations dec ON dec.engine = d.engine AND dec.part = TG_TABLE_NAME AND dec.name = x.key
    LEFT JOIN LATERAL (
      SELECT l.about FROM cortex.flavor_limits l
       WHERE l.flavor = d.flavor AND l.severity = 'refused' AND l.option = dec.id
         AND (l.what = 'option' OR l.what = 'value' AND l.value = x.value)
         AND (l.since IS NULL OR v.position >= (SELECT s.position FROM cortex.engine_versions s WHERE s.id = l.since))
         AND (l."until" IS NULL OR v.position <= (SELECT u.position FROM cortex.engine_versions u WHERE u.id = l."until"))
       LIMIT 1) l ON true
   WHERE r.options <> '{}'::jsonb AND (
         jsonb_typeof(r.options) <> 'object'
      OR dec.id IS NULL
      OR dec.flavor IS NOT NULL AND dec.flavor IS DISTINCT FROM d.flavor
      OR jsonb_typeof(x.value) = 'null' AND NOT dec.nullable
      OR jsonb_typeof(x.value) <> 'null' AND (
           dec.value_type = 'json' AND jsonb_typeof(x.value) NOT IN ('array', 'object')
        OR dec.value_type <> 'json' AND jsonb_typeof(x.value) <> dec.value_type
        OR dec.choices IS NOT NULL AND NOT dec.choices @> jsonb_build_array(x.value)
        OR dec.since IS NOT NULL AND v.position < (SELECT s.position FROM cortex.engine_versions s WHERE s.id = dec.since)
        OR dec."until" IS NOT NULL AND v.position > (SELECT u.position FROM cortex.engine_versions u WHERE u.id = dec."until")
        OR l.about IS NOT NULL))
   LIMIT 1;
  IF NOT FOUND THEN
    -- a value of one of the part's own columns the design's flavor lacks (CockroachDB's deferrable constraints)
    SELECT d.flavor, l.field, l.value, l.about INTO bad
      FROM new_rows r JOIN cortex.designs d ON d.id = r.design
      JOIN cortex.flavor_limits l ON l.flavor = d.flavor AND l.what = 'field' AND l.severity = 'refused' AND l.part = TG_TABLE_NAME
     WHERE to_jsonb(r) -> l.field = l.value
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION '% lacks % = %: %', bad.flavor, bad.field, bad.value, bad.about USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
  END IF;
  IF bad.shape <> 'object' THEN
    RAISE EXCEPTION 'options must be an object, not %', bad.shape USING ERRCODE = 'check_violation';
  ELSIF bad.did IS NULL THEN
    RAISE EXCEPTION 'option % is not declared for % %', bad.key, bad.engine, TG_TABLE_NAME USING ERRCODE = 'check_violation';
  ELSIF bad.dflavor IS NOT NULL AND bad.dflavor IS DISTINCT FROM bad.flavor THEN
    RAISE EXCEPTION 'option % is %''s alone', bad.key, bad.dflavor USING ERRCODE = 'check_violation';
  ELSIF jsonb_typeof(bad.value) = 'null' THEN
    RAISE EXCEPTION 'option % may not be null', bad.key USING ERRCODE = 'check_violation';
  ELSIF bad.value_type = 'json' AND jsonb_typeof(bad.value) NOT IN ('array', 'object')
     OR bad.value_type <> 'json' AND jsonb_typeof(bad.value) <> bad.value_type THEN
    RAISE EXCEPTION 'option % is a %, not a %', bad.key, bad.value_type, jsonb_typeof(bad.value) USING ERRCODE = 'check_violation';
  ELSIF bad.choices IS NOT NULL AND NOT bad.choices @> jsonb_build_array(bad.value) THEN
    RAISE EXCEPTION 'option % may be one of %, not %', bad.key, bad.choices, bad.value USING ERRCODE = 'check_violation';
  ELSIF bad.out_of_version THEN
    RAISE EXCEPTION 'option % is not in % %', bad.key, bad.engine, bad.engine_version USING ERRCODE = 'check_violation';
  ELSE
    RAISE EXCEPTION '% lacks option % = %: %', bad.flavor, bad.key, bad.value, bad.lacks USING ERRCODE = 'check_violation';
  END IF;
END $$;

CREATE TRIGGER options AFTER INSERT ON cortex.namespaces
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.namespaces
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.objects
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.objects
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.columns
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.columns
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.column_identities
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.column_identities
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.constraints
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.constraints
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.constraint_columns
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.constraint_columns
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.dependencies
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.dependencies
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.domains
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.domains
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.enum_values
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.enum_values
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.indexes
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.indexes
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.index_parts
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.index_parts
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.partitionings
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.partitionings
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.partitions
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.partitions
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.routines
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.routines
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.routine_parameters
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.routine_parameters
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.sequences
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.sequences
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.triggers
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.triggers
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.views
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.views
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.memberships
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.memberships
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();

CREATE TRIGGER options AFTER INSERT ON cortex.privileges
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
CREATE TRIGGER options_changed AFTER UPDATE ON cortex.privileges
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION cortex.check_options();
