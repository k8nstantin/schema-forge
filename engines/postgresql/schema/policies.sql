-- engine_postgresql.policies: a row-security policy of a table. Owner: postgresql.
CREATE TABLE engine_postgresql.policies (
  id                UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design            UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  object            UUID NOT NULL,                                                                                 -- the table
  name              TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- its name
  permissive        BOOLEAN NOT NULL DEFAULT true,                                                                 -- false for RESTRICTIVE
  command           TEXT NOT NULL CHECK (command IN ('ALL', 'SELECT', 'INSERT', 'UPDATE', 'DELETE')),              -- the commands it applies to
  roles             JSONB NOT NULL,                                                                                -- the roles it applies to (["public"])
  using_expression  TEXT,                                                                                          -- the rows visible, in the engine's SQL; NULL for none
  check_expression  TEXT,                                                                                          -- the rows that may be written; NULL for none
  UNIQUE (object, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX policies_object ON engine_postgresql.policies (design, object);

COMMENT ON TABLE engine_postgresql.policies IS 'a row-security policy of a table.';
COMMENT ON COLUMN engine_postgresql.policies.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.policies.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.policies.object IS 'the table';
COMMENT ON COLUMN engine_postgresql.policies.name IS 'its name';
COMMENT ON COLUMN engine_postgresql.policies.permissive IS 'false for RESTRICTIVE';
COMMENT ON COLUMN engine_postgresql.policies.command IS 'the commands it applies to';
COMMENT ON COLUMN engine_postgresql.policies.roles IS 'the roles it applies to (["public"])';
COMMENT ON COLUMN engine_postgresql.policies.using_expression IS 'the rows visible, in the engine''s SQL; NULL for none';
COMMENT ON COLUMN engine_postgresql.policies.check_expression IS 'the rows that may be written; NULL for none';
