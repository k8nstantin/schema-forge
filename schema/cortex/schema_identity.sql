-- cortex.schema_identity: the schema this database holds, exactly one row. Owner: cortex.
-- Written when the database is made; only name, comment and engine_version ever change, each by an operation.
CREATE TABLE cortex.schema_identity (
  id              UUID        NOT NULL PRIMARY KEY CHECK (uuid_extract_version(id) = 7),  -- UUIDv7, written when the database is made, never changed: how the workspace and pipelines name this schema, and what its database is named from (sf_<id, hex>)
  name            TEXT        NOT NULL CHECK (length(name) BETWEEN 1 AND 100),            -- as people call it (shop); a rename never moves its database
  engine          TEXT        NOT NULL,                                                   -- the id of the engine it is designed for, as the registry knows it (mysql)
  engine_version  TEXT        NOT NULL,                                                   -- one of the engine's versions; it decides which features the schema is offered (8.4)
  comment         TEXT,                                                                   -- what the schema is for, in a sentence or two
  section_format  INTEGER     NOT NULL DEFAULT 0 CHECK (section_format >= 0),             -- the engine's storage version its options were written in, as the schema's section holds it (0 when it says none)
  created_at      TIMESTAMPTZ NOT NULL,                                                   -- when the database was made
  one             BOOLEAN     NOT NULL DEFAULT true UNIQUE CHECK (one)                    -- keeps the table to one row
);

COMMENT ON TABLE cortex.schema_identity IS 'the schema this database holds, exactly one row. Written when the database is made; only name, comment and engine_version ever change, each by an operation.';
COMMENT ON COLUMN cortex.schema_identity.id IS 'UUIDv7, written when the database is made, never changed: how the workspace and pipelines name this schema, and what its database is named from (sf_<id, hex>)';
COMMENT ON COLUMN cortex.schema_identity.name IS 'as people call it (shop); a rename never moves its database';
COMMENT ON COLUMN cortex.schema_identity.engine IS 'the id of the engine it is designed for, as the registry knows it (mysql)';
COMMENT ON COLUMN cortex.schema_identity.engine_version IS 'one of the engine''s versions; it decides which features the schema is offered (8.4)';
COMMENT ON COLUMN cortex.schema_identity.comment IS 'what the schema is for, in a sentence or two';
COMMENT ON COLUMN cortex.schema_identity.section_format IS 'the engine''s storage version its options were written in, as the schema''s section holds it (0 when it says none)';
COMMENT ON COLUMN cortex.schema_identity.created_at IS 'when the database was made';
COMMENT ON COLUMN cortex.schema_identity.one IS 'keeps the table to one row';
