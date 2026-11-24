-- grant_roles: how an owner's namespace is given to the roles a schema's database is worked through. Owner: cortex.
-- sf_owner owns every namespace, table, view and function and is the only role that changes the schema: every version
-- of every owner runs as it. sf_service is the role the app runs as: it reads and writes rows and the rules run for it,
-- and it can create, alter or drop nothing. sf_reader reads only: the MCP's sql tool and every query sent for reading.
-- The store makes the three roles when it makes the cluster (decision database-roles); every version 1 of an owner in a
-- schema's database ends with cortex.grant_roles('<its namespace>').

CREATE FUNCTION cortex.grant_roles(owner text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', owner);
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO sf_service, sf_reader', owner);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO sf_service', owner);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO sf_reader', owner);
  EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO sf_service', owner);
END $$;

COMMENT ON FUNCTION cortex.grant_roles(text) IS 'gives an owner''s namespace to sf_service (rows, the rules) and sf_reader (reading), so the schema changes only as sf_owner';
