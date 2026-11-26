-- engine_postgresql.user_mappings: who a foreign server is reached as (CREATE USER MAPPING FOR role SERVER server OPTIONS (...)), never with a password: a password option is cut as it is read. Owner: postgresql.
CREATE TABLE engine_postgresql.user_mappings (
  id               UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),              -- UUIDv7, made with the row
  design           UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, -- the design it belongs to
  server           UUID NOT NULL,                                                                                -- the foreign server
  role             UUID,                                                                                         -- the role it is for; NULL when named instead
  role_name        TEXT CHECK (length(role_name) >= 1),                                                          -- the role by name: PUBLIC, or one the design does not hold; NULL when role is set
  mapping_options  JSONB,                                                                                        -- its options as the wrapper takes them (user=remote), never a password; NULL for none
  position         NUMERIC NOT NULL CHECK (position > 0),                                                        -- its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  CHECK (num_nonnulls(role, role_name) = 1),
  UNIQUE (design, id),
  FOREIGN KEY (design, server) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, role) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX user_mappings_server ON engine_postgresql.user_mappings (design, server);
CREATE INDEX user_mappings_role ON engine_postgresql.user_mappings (design, role);

COMMENT ON TABLE engine_postgresql.user_mappings IS 'who a foreign server is reached as (CREATE USER MAPPING FOR role SERVER server OPTIONS (...)), never with a password: a password option is cut as it is read.';
COMMENT ON COLUMN engine_postgresql.user_mappings.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.user_mappings.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.user_mappings.server IS 'the foreign server';
COMMENT ON COLUMN engine_postgresql.user_mappings.role IS 'the role it is for; NULL when named instead';
COMMENT ON COLUMN engine_postgresql.user_mappings.role_name IS 'the role by name: PUBLIC, or one the design does not hold; NULL when role is set';
COMMENT ON COLUMN engine_postgresql.user_mappings.mapping_options IS 'its options as the wrapper takes them (user=remote), never a password; NULL for none';
COMMENT ON COLUMN engine_postgresql.user_mappings.position IS 'its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
