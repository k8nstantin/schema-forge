-- usage.snapshots: one read of a live server's usage, as the server keeps it, taken whenever it is available (decision usage-apart).
-- Appended, never changed and never part of a turn: usage is measured, not designed. Its counts run from the server's start, so
-- two snapshots of one server give what happened between them, and a smaller uptime shows a restart.
-- Owner: usage.
CREATE TABLE usage.snapshots (
  id             UUID        NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),        -- UUIDv7, issued by the database
  design         UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  source_read    UUID        NOT NULL UNIQUE,                                                                   -- the read it was taken in: the connection, the server, the account
  source         TEXT        NOT NULL CHECK (length(source) >= 1),                                              -- where the server keeps its usage, as the engine names it (performance_schema)
  taken_at       TIMESTAMPTZ NOT NULL,                                                                          -- when it was read
  server_uptime  BIGINT      NOT NULL CHECK (server_uptime >= 0),                                               -- the server's uptime in seconds when it was read: what every count runs from
  digests_lost   NUMERIC     NOT NULL DEFAULT 0 CHECK (digests_lost >= 0),                                      -- statements the server counted with no digest of their own because its digest table was full; 0 when every statement has its row
  settings       JSONB,                                                                                         -- the server's settings that shape what it keeps (performance_schema_digests_size, the consumers on), as it gives them; NULL when not read
  UNIQUE (design, id),
  FOREIGN KEY (design, source_read) REFERENCES cortex.source_reads (design, id) ON DELETE CASCADE
);

CREATE INDEX snapshots_source_read ON usage.snapshots (design, source_read);

COMMENT ON TABLE usage.snapshots IS 'one read of a live server''s usage, as the server keeps it, taken whenever it is available (decision usage-apart). Appended, never changed and never part of a turn: usage is measured, not designed. Its counts run from the server''s start, so two snapshots of one server give what happened between them, and a smaller uptime shows a restart.';
COMMENT ON COLUMN usage.snapshots.id IS 'UUIDv7, issued by the database';
COMMENT ON COLUMN usage.snapshots.design IS 'the design it belongs to';
COMMENT ON COLUMN usage.snapshots.source_read IS 'the read it was taken in: the connection, the server, the account';
COMMENT ON COLUMN usage.snapshots.source IS 'where the server keeps its usage, as the engine names it (performance_schema)';
COMMENT ON COLUMN usage.snapshots.taken_at IS 'when it was read';
COMMENT ON COLUMN usage.snapshots.server_uptime IS 'the server''s uptime in seconds when it was read: what every count runs from';
COMMENT ON COLUMN usage.snapshots.digests_lost IS 'statements the server counted with no digest of their own because its digest table was full; 0 when every statement has its row';
COMMENT ON COLUMN usage.snapshots.settings IS 'the server''s settings that shape what it keeps (performance_schema_digests_size, the consumers on), as it gives them; NULL when not read';
