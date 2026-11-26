-- usage.index_usage: what a snapshot says of one index of a table, or of the rows read with none: how often it was read, as the server gives it.
-- An index read nowhere since the server started is a candidate to drop, never a verdict: the snapshot's uptime says how long.
-- Owner: usage.
CREATE TABLE usage.index_usage (
  id             UUID    NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),  -- UUIDv7, issued by the database
  snapshot       UUID    NOT NULL REFERENCES usage.snapshots (id) ON DELETE CASCADE,                  -- the snapshot it is part of
  "index"        BIGINT  REFERENCES cortex.indexes (id) ON DELETE SET NULL,                           -- the design's index of that name when the snapshot was taken; NULL when the design has none, or for rows read with no index
  object_schema  TEXT    NOT NULL CHECK (length(object_schema) >= 1),                                 -- the database its table is in, as the server names it (shop)
  object_name    TEXT    NOT NULL CHECK (length(object_name) >= 1),                                   -- its table, as the server names it (orders)
  index_name     TEXT,                                                                                -- the index, as the server names it (PRIMARY); NULL for the rows read with no index
  rows_read      NUMERIC CHECK (rows_read >= 0),                                                      -- rows read through it since the server started; NULL when not counted
  rows_fetched   NUMERIC CHECK (rows_fetched >= 0),                                                   -- rows fetched through it; NULL when not counted
  rows_inserted  NUMERIC CHECK (rows_inserted >= 0),                                                  -- rows inserted into it; NULL when not counted
  rows_updated   NUMERIC CHECK (rows_updated >= 0),                                                   -- rows updated through it; NULL when not counted
  rows_deleted   NUMERIC CHECK (rows_deleted >= 0),                                                   -- rows deleted through it; NULL when not counted
  io_wait_ps     NUMERIC CHECK (io_wait_ps >= 0),                                                     -- time spent on it, in picoseconds; NULL when not timed
  cardinality    NUMERIC CHECK (cardinality >= 0),                                                    -- the distinct values it holds, as the server estimates them; NULL when it gives none, or for rows read with no index
  source_rows    JSONB   NOT NULL,                                                                    -- every row the server gave of this index, as it gave them, by the table it was read from: what the columns above are taken from, and all the rest
  UNIQUE NULLS NOT DISTINCT (snapshot, object_schema, object_name, index_name)
);

COMMENT ON TABLE usage.index_usage IS 'what a snapshot says of one index of a table, or of the rows read with none: how often it was read, as the server gives it. An index read nowhere since the server started is a candidate to drop, never a verdict: the snapshot''s uptime says how long.';
COMMENT ON COLUMN usage.index_usage.id IS 'UUIDv7, issued by the database';
COMMENT ON COLUMN usage.index_usage.snapshot IS 'the snapshot it is part of';
COMMENT ON COLUMN usage.index_usage."index" IS 'the design''s index of that name when the snapshot was taken; NULL when the design has none, or for rows read with no index';
COMMENT ON COLUMN usage.index_usage.object_schema IS 'the database its table is in, as the server names it (shop)';
COMMENT ON COLUMN usage.index_usage.object_name IS 'its table, as the server names it (orders)';
COMMENT ON COLUMN usage.index_usage.index_name IS 'the index, as the server names it (PRIMARY); NULL for the rows read with no index';
COMMENT ON COLUMN usage.index_usage.rows_read IS 'rows read through it since the server started; NULL when not counted';
COMMENT ON COLUMN usage.index_usage.rows_fetched IS 'rows fetched through it; NULL when not counted';
COMMENT ON COLUMN usage.index_usage.rows_inserted IS 'rows inserted into it; NULL when not counted';
COMMENT ON COLUMN usage.index_usage.rows_updated IS 'rows updated through it; NULL when not counted';
COMMENT ON COLUMN usage.index_usage.rows_deleted IS 'rows deleted through it; NULL when not counted';
COMMENT ON COLUMN usage.index_usage.io_wait_ps IS 'time spent on it, in picoseconds; NULL when not timed';
COMMENT ON COLUMN usage.index_usage.cardinality IS 'the distinct values it holds, as the server estimates them; NULL when it gives none, or for rows read with no index';
COMMENT ON COLUMN usage.index_usage.source_rows IS 'every row the server gave of this index, as it gave them, by the table it was read from: what the columns above are taken from, and all the rest';
