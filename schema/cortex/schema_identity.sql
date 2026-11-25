-- cortex.schema_identity: the schema this database holds, exactly one row. Owner: cortex.
CREATE TABLE cortex.schema_identity (
  id              UUID NOT NULL PRIMARY KEY CHECK (uuid_extract_version(id) = 7),  -- UUIDv7, written when the database is made, never changed: how the workspace and pipelines name this schema
  name            TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),            -- as people call it (shop); a rename never moves its database
  engine          TEXT NOT NULL,                                                   -- the id of the engine it is designed for, as the registry knows it (mysql)
  engine_version  TEXT NOT NULL,                                                   -- one of the engine's versions; it decides which features the schema is offered (8.4)
  comment         TEXT,                                                            -- what the schema is for, in a sentence or two
  created_at      TIMESTAMPTZ NOT NULL,                                            -- when the database was made
  one             BOOLEAN NOT NULL DEFAULT true UNIQUE CHECK (one)                 -- keeps the table to one row
);

COMMENT ON TABLE cortex.schema_identity IS 'the schema this database holds, exactly one row.';
COMMENT ON COLUMN cortex.schema_identity.id IS 'UUIDv7, written when the database is made, never changed: how the workspace and pipelines name this schema';
COMMENT ON COLUMN cortex.schema_identity.name IS 'as people call it (shop); a rename never moves its database';
COMMENT ON COLUMN cortex.schema_identity.engine IS 'the id of the engine it is designed for, as the registry knows it (mysql)';
COMMENT ON COLUMN cortex.schema_identity.engine_version IS 'one of the engine''s versions; it decides which features the schema is offered (8.4)';
COMMENT ON COLUMN cortex.schema_identity.comment IS 'what the schema is for, in a sentence or two';
COMMENT ON COLUMN cortex.schema_identity.created_at IS 'when the database was made';
COMMENT ON COLUMN cortex.schema_identity.one IS 'keeps the table to one row';
