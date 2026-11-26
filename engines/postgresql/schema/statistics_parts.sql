-- engine_postgresql.statistics_parts: what a statistics object counts over (CREATE STATISTICS ... ON a, b, (expr) FROM t), in order: a column the design holds, or an expression. Owner: postgresql.
CREATE TABLE engine_postgresql.statistics_parts (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),              -- UUIDv7, made with the row
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, -- the design it belongs to
  statistics  UUID NOT NULL,                                                                                -- the statistics object
  "column"    UUID,                                                                                         -- the column; NULL for an expression
  expression  TEXT,                                                                                         -- the expression, as PostgreSQL writes it; NULL for a column
  position    NUMERIC NOT NULL CHECK (position > 0),                                                        -- its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  CHECK (num_nonnulls("column", expression) = 1),
  UNIQUE (design, id),
  FOREIGN KEY (design, statistics) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX statistics_parts_statistics ON engine_postgresql.statistics_parts (design, statistics);
CREATE INDEX statistics_parts_column ON engine_postgresql.statistics_parts (design, "column");

COMMENT ON TABLE engine_postgresql.statistics_parts IS 'what a statistics object counts over (CREATE STATISTICS ... ON a, b, (expr) FROM t), in order: a column the design holds, or an expression.';
COMMENT ON COLUMN engine_postgresql.statistics_parts.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.statistics_parts.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.statistics_parts.statistics IS 'the statistics object';
COMMENT ON COLUMN engine_postgresql.statistics_parts."column" IS 'the column; NULL for an expression';
COMMENT ON COLUMN engine_postgresql.statistics_parts.expression IS 'the expression, as PostgreSQL writes it; NULL for a column';
COMMENT ON COLUMN engine_postgresql.statistics_parts.position IS 'its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
