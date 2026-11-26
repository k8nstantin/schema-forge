-- usage.object_usage: what a snapshot says of one table: the rows read and written, the time spent, and its size, as the server gives them.
-- Owner: usage.
CREATE TABLE usage.object_usage (
  id               UUID        NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),        -- UUIDv7, issued by the database
  design           UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  snapshot         UUID        NOT NULL,                                                                          -- the snapshot it is part of
  object           BIGINT,                                                                                        -- the design's object of that name when the snapshot was taken; NULL when the design has none
  object_schema    TEXT        NOT NULL CHECK (length(object_schema) >= 1),                                       -- the database it is in, as the server names it (shop)
  object_name      TEXT        NOT NULL CHECK (length(object_name) >= 1),                                         -- the table, as the server names it (orders)
  rows_read        NUMERIC     CHECK (rows_read >= 0),                                                            -- rows read since the server started; NULL when the server does not count them
  rows_written     NUMERIC     CHECK (rows_written >= 0),                                                         -- rows written (inserted, updated or deleted) since the server started; NULL when not counted
  rows_fetched     NUMERIC     CHECK (rows_fetched >= 0),                                                         -- rows fetched; NULL when not counted
  rows_inserted    NUMERIC     CHECK (rows_inserted >= 0),                                                        -- rows inserted; NULL when not counted
  rows_updated     NUMERIC     CHECK (rows_updated >= 0),                                                         -- rows updated; NULL when not counted
  rows_deleted     NUMERIC     CHECK (rows_deleted >= 0),                                                         -- rows deleted; NULL when not counted
  io_wait_ps       NUMERIC     CHECK (io_wait_ps >= 0),                                                           -- time spent reading and writing its rows, in picoseconds; NULL when not timed
  lock_wait_ps     NUMERIC     CHECK (lock_wait_ps >= 0),                                                         -- time spent waiting for its locks, in picoseconds; NULL when not timed
  estimated_rows   NUMERIC     CHECK (estimated_rows >= 0),                                                       -- the rows it holds, as the server estimates them; NULL when it gives none
  data_bytes       NUMERIC     CHECK (data_bytes >= 0),                                                           -- the size of its rows, in bytes, as the server estimates it; NULL when it gives none
  index_bytes      NUMERIC     CHECK (index_bytes >= 0),                                                          -- the size of its indexes, in bytes, as the server estimates it; NULL when it gives none
  last_written_at  TIMESTAMPTZ,                                                                                   -- when its rows were last changed, as the server knows it (lost when it restarts); NULL when it does not know
  source_rows      JSONB       NOT NULL,                                                                          -- every row the server gave of this table, as it gave them, by the table it was read from: what the columns above are taken from, and all the rest
  UNIQUE (snapshot, object_schema, object_name),
  UNIQUE (design, id),
  FOREIGN KEY (design, snapshot) REFERENCES usage.snapshots (design, id) ON DELETE CASCADE,
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE SET NULL (object)
);

CREATE INDEX object_usage_snapshot ON usage.object_usage (design, snapshot);
CREATE INDEX object_usage_object ON usage.object_usage (design, object);

COMMENT ON TABLE usage.object_usage IS 'what a snapshot says of one table: the rows read and written, the time spent, and its size, as the server gives them.';
COMMENT ON COLUMN usage.object_usage.id IS 'UUIDv7, issued by the database';
COMMENT ON COLUMN usage.object_usage.design IS 'the design it belongs to';
COMMENT ON COLUMN usage.object_usage.snapshot IS 'the snapshot it is part of';
COMMENT ON COLUMN usage.object_usage.object IS 'the design''s object of that name when the snapshot was taken; NULL when the design has none';
COMMENT ON COLUMN usage.object_usage.object_schema IS 'the database it is in, as the server names it (shop)';
COMMENT ON COLUMN usage.object_usage.object_name IS 'the table, as the server names it (orders)';
COMMENT ON COLUMN usage.object_usage.rows_read IS 'rows read since the server started; NULL when the server does not count them';
COMMENT ON COLUMN usage.object_usage.rows_written IS 'rows written (inserted, updated or deleted) since the server started; NULL when not counted';
COMMENT ON COLUMN usage.object_usage.rows_fetched IS 'rows fetched; NULL when not counted';
COMMENT ON COLUMN usage.object_usage.rows_inserted IS 'rows inserted; NULL when not counted';
COMMENT ON COLUMN usage.object_usage.rows_updated IS 'rows updated; NULL when not counted';
COMMENT ON COLUMN usage.object_usage.rows_deleted IS 'rows deleted; NULL when not counted';
COMMENT ON COLUMN usage.object_usage.io_wait_ps IS 'time spent reading and writing its rows, in picoseconds; NULL when not timed';
COMMENT ON COLUMN usage.object_usage.lock_wait_ps IS 'time spent waiting for its locks, in picoseconds; NULL when not timed';
COMMENT ON COLUMN usage.object_usage.estimated_rows IS 'the rows it holds, as the server estimates them; NULL when it gives none';
COMMENT ON COLUMN usage.object_usage.data_bytes IS 'the size of its rows, in bytes, as the server estimates it; NULL when it gives none';
COMMENT ON COLUMN usage.object_usage.index_bytes IS 'the size of its indexes, in bytes, as the server estimates it; NULL when it gives none';
COMMENT ON COLUMN usage.object_usage.last_written_at IS 'when its rows were last changed, as the server knows it (lost when it restarts); NULL when it does not know';
COMMENT ON COLUMN usage.object_usage.source_rows IS 'every row the server gave of this table, as it gave them, by the table it was read from: what the columns above are taken from, and all the rest';
