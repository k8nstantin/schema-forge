-- cortex.source_reads: each read of a live database for this schema: from which saved connection, which server, as whom, and when.
-- An import lands in its turn; a read of usage alone has none (decision usage-apart). The connection is the workspace's, in
-- another database, so it is kept by its id and name, not a foreign key.
-- Owner: cortex.
CREATE TABLE cortex.source_reads (
  id               UUID        NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),  -- UUIDv7, issued by the database
  turn             UUID        REFERENCES cortex.turns (id),                    -- the import turn the structure read landed in; NULL for a read of usage alone
  connection_id    UUID        NOT NULL,                                        -- the saved connection read through, as the workspace's connections row holds it
  connection_name  TEXT        NOT NULL CHECK (length(connection_name) >= 1),   -- its name when it was read (prod-replica)
  database_name    TEXT        NOT NULL CHECK (length(database_name) >= 1),     -- the database read, as the server names it (shop)
  scope            JSONB       NOT NULL,                                        -- what the person asked to read (decision read-scope): everything, or the parts (definitions, metadata, usage), the kinds of object and the objects chosen
  server_version   TEXT        NOT NULL CHECK (length(server_version) >= 1),    -- the version the server gave (8.4.13)
  server_edition   TEXT,                                                        -- what the server says it is beyond its version (MySQL Community Server - GPL); NULL when it says nothing
  read_as          TEXT        NOT NULL CHECK (length(read_as) >= 1),           -- the account the server says the read ran as (sf_reader@%)
  server_uptime    BIGINT      CHECK (server_uptime >= 0),                      -- the server's uptime in seconds when read: usage counts from its start; NULL when it would not say
  usage_available  BOOLEAN     NOT NULL,                                        -- whether the server keeps usage (MySQL: performance_schema on) and the account could read it
  missing_grants   TEXT,                                                        -- the grants the account lacked, as the test named them, and so what was not read; NULL for none
  started_at       TIMESTAMPTZ NOT NULL,                                        -- when the read began
  ended_at         TIMESTAMPTZ,                                                 -- when it ended; NULL while it runs
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);

COMMENT ON TABLE cortex.source_reads IS 'each read of a live database for this schema: from which saved connection, which server, as whom, and when. An import lands in its turn; a read of usage alone has none (decision usage-apart). The connection is the workspace''s, in another database, so it is kept by its id and name, not a foreign key.';
COMMENT ON COLUMN cortex.source_reads.id IS 'UUIDv7, issued by the database';
COMMENT ON COLUMN cortex.source_reads.turn IS 'the import turn the structure read landed in; NULL for a read of usage alone';
COMMENT ON COLUMN cortex.source_reads.connection_id IS 'the saved connection read through, as the workspace''s connections row holds it';
COMMENT ON COLUMN cortex.source_reads.connection_name IS 'its name when it was read (prod-replica)';
COMMENT ON COLUMN cortex.source_reads.database_name IS 'the database read, as the server names it (shop)';
COMMENT ON COLUMN cortex.source_reads.scope IS 'what the person asked to read (decision read-scope): everything, or the parts (definitions, metadata, usage), the kinds of object and the objects chosen';
COMMENT ON COLUMN cortex.source_reads.server_version IS 'the version the server gave (8.4.13)';
COMMENT ON COLUMN cortex.source_reads.server_edition IS 'what the server says it is beyond its version (MySQL Community Server - GPL); NULL when it says nothing';
COMMENT ON COLUMN cortex.source_reads.read_as IS 'the account the server says the read ran as (sf_reader@%)';
COMMENT ON COLUMN cortex.source_reads.server_uptime IS 'the server''s uptime in seconds when read: usage counts from its start; NULL when it would not say';
COMMENT ON COLUMN cortex.source_reads.usage_available IS 'whether the server keeps usage (MySQL: performance_schema on) and the account could read it';
COMMENT ON COLUMN cortex.source_reads.missing_grants IS 'the grants the account lacked, as the test named them, and so what was not read; NULL for none';
COMMENT ON COLUMN cortex.source_reads.started_at IS 'when the read began';
COMMENT ON COLUMN cortex.source_reads.ended_at IS 'when it ended; NULL while it runs';
