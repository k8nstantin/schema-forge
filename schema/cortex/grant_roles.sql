-- grant_roles: how an owner's namespace is given to the roles schema_forge is worked through. Owner: cortex.
-- sf_owner owns every namespace, table, view and function and is the only role that changes the schema: every version
-- of every owner runs as it. sf_service is the role the app runs as: it reads and writes rows and the rules run for it,
-- and it can create, alter or drop nothing. sf_agent is the role of a coding agent's own service account: it reads
-- everything and writes the design's rows, the log's new rows with them, and can create, alter or drop nothing; what
-- the engine declares, what was applied, what was read and what was locked it reads only, and the log it never
-- rewrites. sf_reader reads only: the MCP's sql tool and every query sent for reading. The store makes the four roles
-- when it makes the cluster (decision database-roles); every version 1 of an owner in schema_forge ends with
-- cortex.grant_roles('<its namespace>').

CREATE FUNCTION cortex.grant_roles(owner text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  t text;
BEGIN
  EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', owner);
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO sf_service, sf_agent, sf_reader', owner);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO sf_service, sf_agent', owner);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO sf_reader', owner);
  -- no function by default: PostgreSQL lets everyone execute a new function; here only what a job needs (cortex.misfits)
  EXECUTE format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC, sf_service, sf_agent, sf_reader', owner);
  -- and the same for every table and function a later version makes (they are made as sf_owner)
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO sf_service, sf_agent', owner);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA %I GRANT SELECT ON TABLES TO sf_reader', owner);
  EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC';
  IF owner = 'cortex' THEN
    -- what the agent reads only: the designs themselves, the engines' declarations, the workspace, what a person chose
    -- to read, what was applied, read and locked
    FOREACH t IN ARRAY ARRAY['designs', 'engine_versions', 'engine_features', 'catalog_sources', 'object_kinds', 'option_declarations', 'engine_flavors', 'flavor_limits', 'reference_kinds', 'privilege_declarations',
                             'workspace_identity', 'workspace_parameters', 'workspace_connections', 'workspace_connection_values',
                             'workspace_connection_tests', 'workspace_connection_test_steps', 'workspace_design_connections',
                             'read_scopes', 'read_scope_kinds', 'read_scope_objects',
                             'schema_migrations', 'source_reads', 'locked_versions'] LOOP
      EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON cortex.%I FROM sf_agent', t);
    END LOOP;
    -- what the engines declare (their versions, features, kinds, options, catalog sources, flavors and what each flavor
    -- lacks) is the seeds' alone, changed by installing a version as the DBA: the app reads it, as the agent does
    FOREACH t IN ARRAY ARRAY['engine_versions', 'engine_features', 'catalog_sources', 'object_kinds', 'option_declarations', 'engine_flavors',
                             'flavor_limits', 'reference_kinds', 'privilege_declarations'] LOOP
      EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON cortex.%I FROM sf_service', t);
    END LOOP;
    -- the log: the agent adds to it with its work and never rewrites it; the app adds to it, and of a turn changes only
    -- its state as it ends or is decided: no row of history is rewritten or deleted (a design deleted takes its log with
    -- it, as the table owner, by the foreign keys)
    FOREACH t IN ARRAY ARRAY['turns', 'operations', 'row_changes'] LOOP
      EXECUTE format('REVOKE UPDATE, DELETE ON cortex.%I FROM sf_agent', t);
    END LOOP;
    REVOKE UPDATE, DELETE ON cortex.operations, cortex.row_changes FROM sf_service;
    REVOKE DELETE ON cortex.turns FROM sf_service;
    -- what was migrated is the owner's to write; a version locked stays as it was locked
    REVOKE INSERT, UPDATE, DELETE ON cortex.schema_migrations FROM sf_service;
    REVOKE UPDATE, DELETE ON cortex.locked_versions FROM sf_service;
    -- the one function a job needs: what a design holds that a target would not take
    GRANT EXECUTE ON FUNCTION cortex.misfits(uuid, text, text) TO sf_service, sf_agent, sf_reader;
    -- the database: the service accounts connect to it, and make nothing in it, not even a temporary table
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO sf_service, sf_agent, sf_reader', current_database());
  END IF;
END $$;

COMMENT ON FUNCTION cortex.grant_roles(text) IS 'gives an owner''s namespace to sf_service (rows, the rules), sf_agent (the design''s rows) and sf_reader (reading), so the schema changes only as sf_owner';
