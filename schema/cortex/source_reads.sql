-- cortex.source_reads: each read of a live database for a design: from which saved connection, which server, as whom, by which choice, and when. Owner: cortex.
CREATE TABLE cortex.source_reads (
  id               UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                     -- UUIDv7, issued by the database
  design           UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,        -- the design it was read for
  turn             UUID,                                                                                                -- the import turn its definitions landed in; NULL when the read ended before it had one (refused, stopped)
  scope            UUID NOT NULL,                                                                                       -- the choice it ran with (decision read-scope)
  connection       UUID REFERENCES cortex.workspace_connections (id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,  -- the saved connection read through; NULL once it is deleted
  connection_name  TEXT NOT NULL CHECK (length(connection_name) >= 1),                                                  -- its name when it was read (prod-replica)
  database_name    TEXT NOT NULL CHECK (length(database_name) >= 1),                                                    -- the database read, as the server names it (shop)
  server_version   TEXT NOT NULL CHECK (length(server_version) >= 1),                                                   -- the version the server gave (8.4.13)
  server_edition   TEXT,                                                                                                -- what the server says it is beyond its version; NULL when it says nothing
  read_as          TEXT NOT NULL CHECK (length(read_as) >= 1),                                                          -- the account the server says the read ran as (sf_reader@%)
  missing_grants   TEXT,                                                                                                -- the grants the account lacked, and so what was not read; NULL for none
  started_at       TIMESTAMPTZ NOT NULL,                                                                                -- when the read began
  ended_at         TIMESTAMPTZ,                                                                                         -- when it ended; NULL while it runs
  CHECK (ended_at IS NULL OR ended_at >= started_at),
  UNIQUE (design, id),
  FOREIGN KEY (design, turn) REFERENCES cortex.turns (design, id),
  FOREIGN KEY (design, scope) REFERENCES cortex.read_scopes (design, id) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX source_reads_turn ON cortex.source_reads (design, turn);
CREATE INDEX source_reads_scope ON cortex.source_reads (design, scope);

COMMENT ON TABLE cortex.source_reads IS 'each read of a live database for a design: from which saved connection, which server, as whom, by which choice, and when.';
COMMENT ON COLUMN cortex.source_reads.id IS 'UUIDv7, issued by the database';
COMMENT ON COLUMN cortex.source_reads.design IS 'the design it was read for';
COMMENT ON COLUMN cortex.source_reads.turn IS 'the import turn its definitions landed in; NULL when the read ended before it had one (refused, stopped)';
COMMENT ON COLUMN cortex.source_reads.scope IS 'the choice it ran with (decision read-scope)';
COMMENT ON COLUMN cortex.source_reads.connection IS 'the saved connection read through; NULL once it is deleted';
COMMENT ON COLUMN cortex.source_reads.connection_name IS 'its name when it was read (prod-replica)';
COMMENT ON COLUMN cortex.source_reads.database_name IS 'the database read, as the server names it (shop)';
COMMENT ON COLUMN cortex.source_reads.server_version IS 'the version the server gave (8.4.13)';
COMMENT ON COLUMN cortex.source_reads.server_edition IS 'what the server says it is beyond its version; NULL when it says nothing';
COMMENT ON COLUMN cortex.source_reads.read_as IS 'the account the server says the read ran as (sf_reader@%)';
COMMENT ON COLUMN cortex.source_reads.missing_grants IS 'the grants the account lacked, and so what was not read; NULL for none';
COMMENT ON COLUMN cortex.source_reads.started_at IS 'when the read began';
COMMENT ON COLUMN cortex.source_reads.ended_at IS 'when it ended; NULL while it runs';
