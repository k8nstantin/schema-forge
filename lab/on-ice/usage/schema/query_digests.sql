-- usage.query_digests: what a snapshot says of one kind of statement, its values made placeholders: how often it ran, what it cost and what it read, as the server gives it.
-- Kept as the server gives it, its sample text too: the read runs inside the source's own network, as its read-only service account.
-- Only statements that ran in the database read are kept: the server counts every database's.
-- Owner: usage.
CREATE TABLE usage.query_digests (
  id                  UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, issued by the database
  design              UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  snapshot            UUID NOT NULL,                                                                                 -- the snapshot it is part of
  schema_name         TEXT NOT NULL CHECK (length(schema_name) >= 1),                                                -- the database it ran in, as the server names it: the database read (shop)
  digest              TEXT NOT NULL CHECK (length(digest) >= 1),                                                     -- the server's hash of the statement with its values made placeholders
  digest_text         TEXT,                                                                                          -- the statement with its values as ?, as the server gives it; NULL when it keeps none
  executions          NUMERIC NOT NULL CHECK (executions >= 0),                                                      -- how often it ran since the server started
  total_wait_ps       NUMERIC CHECK (total_wait_ps >= 0),                                                            -- the time all its runs took, in picoseconds; NULL when not timed
  max_wait_ps         NUMERIC CHECK (max_wait_ps >= 0),                                                              -- the longest run, in picoseconds; NULL when not timed
  p95_ps              NUMERIC CHECK (p95_ps >= 0),                                                                   -- 95 runs in 100 took no longer, in picoseconds; NULL when the server does not keep it (before 8.0)
  p99_ps              NUMERIC CHECK (p99_ps >= 0),                                                                   -- 99 runs in 100 took no longer, in picoseconds; NULL when the server does not keep it
  p999_ps             NUMERIC CHECK (p999_ps >= 0),                                                                  -- 999 runs in 1000 took no longer, in picoseconds; NULL when the server does not keep it
  cpu_ps              NUMERIC CHECK (cpu_ps >= 0),                                                                   -- the processor time its runs took, in picoseconds; NULL when the server does not keep it
  rows_examined       NUMERIC CHECK (rows_examined >= 0),                                                            -- rows its runs looked at; NULL when not counted
  rows_sent           NUMERIC CHECK (rows_sent >= 0),                                                                -- rows its runs returned; NULL when not counted
  rows_affected       NUMERIC CHECK (rows_affected >= 0),                                                            -- rows its runs changed; NULL when not counted
  no_index_used       NUMERIC CHECK (no_index_used >= 0),                                                            -- runs that read a table with no index; NULL when not counted
  no_good_index_used  NUMERIC CHECK (no_good_index_used >= 0),                                                       -- runs that found no good index; NULL when not counted
  full_joins          NUMERIC CHECK (full_joins >= 0),                                                               -- runs that joined by reading a whole table; NULL when not counted
  temp_tables         NUMERIC CHECK (temp_tables >= 0),                                                              -- temporary tables its runs made; NULL when not counted
  temp_disk_tables    NUMERIC CHECK (temp_disk_tables >= 0),                                                         -- of those, the ones written to disk; NULL when not counted
  sorted_rows         NUMERIC CHECK (sorted_rows >= 0),                                                              -- rows its runs sorted; NULL when not counted
  errors              NUMERIC CHECK (errors >= 0),                                                                   -- runs that ended in an error; NULL when not counted
  warnings            NUMERIC CHECK (warnings >= 0),                                                                 -- warnings its runs raised; NULL when not counted
  sample_text         TEXT,                                                                                          -- one run's statement with its values, as the server kept it; NULL when it keeps none (before 8.0)
  sample_seen         TIMESTAMPTZ,                                                                                   -- when that run was; NULL with no sample
  first_seen          TIMESTAMPTZ,                                                                                   -- when it first ran since the server started, by the server's clock; NULL when not given
  last_seen           TIMESTAMPTZ,                                                                                   -- when it last ran, by the server's clock; NULL when not given
  source_row          JSONB NOT NULL,                                                                                -- the row the server gave, as it gave it: what the columns above are taken from, and all the rest
  UNIQUE (snapshot, schema_name, digest),
  UNIQUE (design, id),
  FOREIGN KEY (design, snapshot) REFERENCES usage.snapshots (design, id) ON DELETE CASCADE
);

CREATE INDEX query_digests_snapshot ON usage.query_digests (design, snapshot);

COMMENT ON TABLE usage.query_digests IS 'what a snapshot says of one kind of statement, its values made placeholders: how often it ran, what it cost and what it read, as the server gives it. Kept as the server gives it, its sample text too: the read runs inside the source''s own network, as its read-only service account. Only statements that ran in the database read are kept: the server counts every database''s.';
COMMENT ON COLUMN usage.query_digests.id IS 'UUIDv7, issued by the database';
COMMENT ON COLUMN usage.query_digests.design IS 'the design it belongs to';
COMMENT ON COLUMN usage.query_digests.snapshot IS 'the snapshot it is part of';
COMMENT ON COLUMN usage.query_digests.schema_name IS 'the database it ran in, as the server names it: the database read (shop)';
COMMENT ON COLUMN usage.query_digests.digest IS 'the server''s hash of the statement with its values made placeholders';
COMMENT ON COLUMN usage.query_digests.digest_text IS 'the statement with its values as ?, as the server gives it; NULL when it keeps none';
COMMENT ON COLUMN usage.query_digests.executions IS 'how often it ran since the server started';
COMMENT ON COLUMN usage.query_digests.total_wait_ps IS 'the time all its runs took, in picoseconds; NULL when not timed';
COMMENT ON COLUMN usage.query_digests.max_wait_ps IS 'the longest run, in picoseconds; NULL when not timed';
COMMENT ON COLUMN usage.query_digests.p95_ps IS '95 runs in 100 took no longer, in picoseconds; NULL when the server does not keep it (before 8.0)';
COMMENT ON COLUMN usage.query_digests.p99_ps IS '99 runs in 100 took no longer, in picoseconds; NULL when the server does not keep it';
COMMENT ON COLUMN usage.query_digests.p999_ps IS '999 runs in 1000 took no longer, in picoseconds; NULL when the server does not keep it';
COMMENT ON COLUMN usage.query_digests.cpu_ps IS 'the processor time its runs took, in picoseconds; NULL when the server does not keep it';
COMMENT ON COLUMN usage.query_digests.rows_examined IS 'rows its runs looked at; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.rows_sent IS 'rows its runs returned; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.rows_affected IS 'rows its runs changed; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.no_index_used IS 'runs that read a table with no index; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.no_good_index_used IS 'runs that found no good index; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.full_joins IS 'runs that joined by reading a whole table; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.temp_tables IS 'temporary tables its runs made; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.temp_disk_tables IS 'of those, the ones written to disk; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.sorted_rows IS 'rows its runs sorted; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.errors IS 'runs that ended in an error; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.warnings IS 'warnings its runs raised; NULL when not counted';
COMMENT ON COLUMN usage.query_digests.sample_text IS 'one run''s statement with its values, as the server kept it; NULL when it keeps none (before 8.0)';
COMMENT ON COLUMN usage.query_digests.sample_seen IS 'when that run was; NULL with no sample';
COMMENT ON COLUMN usage.query_digests.first_seen IS 'when it first ran since the server started, by the server''s clock; NULL when not given';
COMMENT ON COLUMN usage.query_digests.last_seen IS 'when it last ran, by the server''s clock; NULL when not given';
COMMENT ON COLUMN usage.query_digests.source_row IS 'the row the server gave, as it gave it: what the columns above are taken from, and all the rest';
