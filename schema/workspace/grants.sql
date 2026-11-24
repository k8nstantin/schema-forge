-- grants: the workspace's namespace given to the roles, as cortex.grant_roles gives an owner's in a schema's database. Owner: workspace.
-- The workspace's database holds no cortex, so its version 1 ends with these statements (decision database-roles).
REVOKE ALL ON SCHEMA workspace FROM PUBLIC;
GRANT USAGE ON SCHEMA workspace TO sf_service, sf_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA workspace TO sf_service;
GRANT SELECT ON ALL TABLES IN SCHEMA workspace TO sf_reader;
-- and the same for every table a later version makes (they are made as sf_owner)
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA workspace GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO sf_service;
ALTER DEFAULT PRIVILEGES FOR ROLE sf_owner IN SCHEMA workspace GRANT SELECT ON TABLES TO sf_reader;
