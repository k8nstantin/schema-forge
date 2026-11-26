-- engine_postgresql.namespaces: who owns a PostgreSQL schema and who may use it. Owner: postgresql.
CREATE TABLE engine_postgresql.namespaces (
  id      BIGINT NOT NULL PRIMARY KEY,                                                                   -- the schema
  design  UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  owner   TEXT,                                                                                          -- its owner, by role name; NULL for the one the schema is written as
  acl     JSONB,                                                                                         -- its privileges, as the server writes them (["postgres=UC/postgres"]); NULL for the defaults
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_postgresql.namespaces IS 'who owns a PostgreSQL schema and who may use it.';
COMMENT ON COLUMN engine_postgresql.namespaces.id IS 'the schema';
COMMENT ON COLUMN engine_postgresql.namespaces.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.namespaces.owner IS 'its owner, by role name; NULL for the one the schema is written as';
COMMENT ON COLUMN engine_postgresql.namespaces.acl IS 'its privileges, as the server writes them (["postgres=UC/postgres"]); NULL for the defaults';
