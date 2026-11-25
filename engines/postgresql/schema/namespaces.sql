-- engine_postgresql.namespaces: who owns a PostgreSQL schema and who may use it. Owner: postgresql.
CREATE TABLE engine_postgresql.namespaces (
  id     BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.namespaces (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the schema
  owner  TEXT,                                                                                                           -- its owner, by role name; NULL for the one the schema is written as
  acl    JSONB                                                                                                           -- its privileges, as the server writes them (["postgres=UC/postgres"]); NULL for the defaults
);

COMMENT ON TABLE engine_postgresql.namespaces IS 'who owns a PostgreSQL schema and who may use it.';
COMMENT ON COLUMN engine_postgresql.namespaces.id IS 'the schema';
COMMENT ON COLUMN engine_postgresql.namespaces.owner IS 'its owner, by role name; NULL for the one the schema is written as';
COMMENT ON COLUMN engine_postgresql.namespaces.acl IS 'its privileges, as the server writes them (["postgres=UC/postgres"]); NULL for the defaults';
