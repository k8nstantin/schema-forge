-- engine_mysql.check_flavor: what a MySQL design's flavor refuses or adds, held as its rows are written, from the facts
-- its flavor declares (cortex.engine_flavors refuses and options): a storage engine it refuses; a partitioning method it
-- refuses; a privilege it refuses; a table option it refuses (refuses.table_options, a column of engine_mysql.tables);
-- a database name it reserves; a flavor_options key it does not declare for that table, or of another JSON type.
-- What every engine refuses the same way (a kind the flavor or version lacks) is the cortex's (cortex.check_object).
-- It runs as the writer, so it reads only the designs the writer may.

CREATE FUNCTION engine_mysql.check_flavor() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, engine_mysql AS $$
DECLARE
  f        cortex.engine_flavors;
  row      jsonb := to_jsonb(NEW);
  allowed  jsonb;
  k        text;
BEGIN
  SELECT x.* INTO f FROM cortex.engine_flavors x JOIN cortex.designs d ON d.engine = x.engine AND d.flavor = x.flavor WHERE d.id = NEW.design;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF TG_TABLE_NAME = 'tables' AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(f.refuses -> 'engines', '[]')) e WHERE upper(e) = upper(row ->> 'engine')) THEN
    RAISE EXCEPTION '% refuses the storage engine %', f.name, row ->> 'engine' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_TABLE_NAME = 'tables' THEN
    SELECT o INTO k FROM jsonb_array_elements_text(coalesce(f.refuses -> 'table_options', '[]')) o WHERE row -> o IS NOT NULL AND row -> o <> 'null' LIMIT 1;
    IF k IS NOT NULL THEN
      RAISE EXCEPTION '% refuses the table option %', f.name, upper(k) USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF TG_TABLE_NAME = 'databases' AND coalesce(f.refuses -> 'database_names', '[]') ? (SELECT name FROM cortex.namespaces WHERE id = NEW.id) THEN
    RAISE EXCEPTION '% refuses a database named %', f.name, (SELECT name FROM cortex.namespaces WHERE id = NEW.id) USING ERRCODE = 'check_violation';
  END IF;
  IF TG_TABLE_NAME = 'partitionings' AND coalesce(f.refuses -> 'partition_methods', '[]') ? (row ->> 'method') THEN
    RAISE EXCEPTION '% refuses partitioning by %', f.name, row ->> 'method' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_TABLE_NAME = 'privileges' AND coalesce(f.refuses -> 'privileges', '[]') ? (row ->> 'privilege') THEN
    RAISE EXCEPTION '% refuses the privilege %', f.name, row ->> 'privilege' USING ERRCODE = 'check_violation';
  END IF;
  IF row ? 'flavor_options' THEN
    allowed := coalesce(f.options -> TG_TABLE_NAME, '{}');
    FOR k IN SELECT jsonb_object_keys(row -> 'flavor_options') LOOP
      IF NOT allowed ? k THEN
        RAISE EXCEPTION '% declares no flavor option % on %', f.name, k, TG_TABLE_NAME USING ERRCODE = 'check_violation';
      END IF;
      IF jsonb_typeof(row -> 'flavor_options' -> k) <> (allowed ->> k) THEN
        RAISE EXCEPTION '% declares the flavor option % on % a %, not a %', f.name, k, TG_TABLE_NAME, allowed ->> k, jsonb_typeof(row -> 'flavor_options' -> k)
          USING ERRCODE = 'check_violation';
      END IF;
    END LOOP;
  END IF;
  RETURN NULL;
END $$;

COMMENT ON FUNCTION engine_mysql.check_flavor() IS 'refuses what a MySQL design''s flavor refuses (a storage engine, a partitioning method, a privilege) and any flavor_options key it does not declare, or of another type';

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['instances', 'databases', 'tables', 'columns', 'indexes', 'partitionings', 'partitions', 'views', 'routines', 'privileges'] LOOP
    EXECUTE format('CREATE CONSTRAINT TRIGGER check_flavor AFTER INSERT OR UPDATE ON engine_mysql.%I DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION engine_mysql.check_flavor()', t);
  END LOOP;
END $$;
