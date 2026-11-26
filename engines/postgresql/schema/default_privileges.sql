-- engine_postgresql.default_privileges: what a role's future objects grant as they are made (ALTER DEFAULT PRIVILEGES FOR ROLE ... IN SCHEMA ... GRANT ... ON TABLES TO ...), one privilege a row. Owner: postgresql.
CREATE TABLE engine_postgresql.default_privileges (
  id            UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                                -- UUIDv7, made with the row
  design        UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,                   -- the design it belongs to
  role          UUID NOT NULL,                                                                                                  -- the role whose future objects it is for (FOR ROLE)
  namespace     UUID,                                                                                                           -- the schema it is in (IN SCHEMA); NULL for every schema
  object_type   TEXT NOT NULL CHECK (object_type IN ('tables', 'sequences', 'functions', 'types', 'schemas', 'large_objects')), -- the kind of object it is for, as the statement names it (ON TABLES)
  grantee       UUID,                                                                                                           -- the role given it; NULL when it is named instead
  grantee_name  TEXT CHECK (length(grantee_name) >= 1),                                                                         -- the grantee by name: PUBLIC; NULL when grantee is set
  privilege     TEXT NOT NULL CHECK (privilege ~ '^[A-Z][A-Z_ ]*$'),                                                            -- as PostgreSQL names it (SELECT, EXECUTE)
  grantable     BOOLEAN NOT NULL DEFAULT false,                                                                                 -- true when the grantee may give it on (WITH GRANT OPTION)
  position      NUMERIC NOT NULL CHECK (position > 0),                                                                          -- its place among the role's defaults, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  UNIQUE NULLS NOT DISTINCT (design, role, namespace, object_type, grantee, grantee_name, privilege) DEFERRABLE INITIALLY DEFERRED,
  CHECK (num_nonnulls(grantee, grantee_name) = 1),
  UNIQUE (design, id),
  FOREIGN KEY (design, role) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, namespace) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, grantee) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX default_privileges_role ON engine_postgresql.default_privileges (design, role);
CREATE INDEX default_privileges_namespace ON engine_postgresql.default_privileges (design, namespace);
CREATE INDEX default_privileges_grantee ON engine_postgresql.default_privileges (design, grantee);

COMMENT ON TABLE engine_postgresql.default_privileges IS 'what a role''s future objects grant as they are made (ALTER DEFAULT PRIVILEGES FOR ROLE ... IN SCHEMA ... GRANT ... ON TABLES TO ...), one privilege a row.';
COMMENT ON COLUMN engine_postgresql.default_privileges.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.default_privileges.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.default_privileges.role IS 'the role whose future objects it is for (FOR ROLE)';
COMMENT ON COLUMN engine_postgresql.default_privileges.namespace IS 'the schema it is in (IN SCHEMA); NULL for every schema';
COMMENT ON COLUMN engine_postgresql.default_privileges.object_type IS 'the kind of object it is for, as the statement names it (ON TABLES)';
COMMENT ON COLUMN engine_postgresql.default_privileges.grantee IS 'the role given it; NULL when it is named instead';
COMMENT ON COLUMN engine_postgresql.default_privileges.grantee_name IS 'the grantee by name: PUBLIC; NULL when grantee is set';
COMMENT ON COLUMN engine_postgresql.default_privileges.privilege IS 'as PostgreSQL names it (SELECT, EXECUTE)';
COMMENT ON COLUMN engine_postgresql.default_privileges.grantable IS 'true when the grantee may give it on (WITH GRANT OPTION)';
COMMENT ON COLUMN engine_postgresql.default_privileges.position IS 'its place among the role''s defaults, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
