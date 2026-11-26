-- engine_postgresql.publication_table_columns: the columns a published table publishes, where it names some (FOR TABLE t (a, b)), in their order. Owner: postgresql.
CREATE TABLE engine_postgresql.publication_table_columns (
  id                 UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),              -- UUIDv7, made with the row
  design             UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, -- the design it belongs to
  publication_table  UUID NOT NULL,                                                                                -- the published table
  "column"           UUID NOT NULL,                                                                                -- the column published
  position           NUMERIC NOT NULL CHECK (position > 0),                                                        -- its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  UNIQUE (design, id),
  FOREIGN KEY (design, publication_table) REFERENCES engine_postgresql.publication_tables (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX publication_table_columns_publication_table ON engine_postgresql.publication_table_columns (design, publication_table);
CREATE INDEX publication_table_columns_column ON engine_postgresql.publication_table_columns (design, "column");

COMMENT ON TABLE engine_postgresql.publication_table_columns IS 'the columns a published table publishes, where it names some (FOR TABLE t (a, b)), in their order.';
COMMENT ON COLUMN engine_postgresql.publication_table_columns.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.publication_table_columns.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.publication_table_columns.publication_table IS 'the published table';
COMMENT ON COLUMN engine_postgresql.publication_table_columns."column" IS 'the column published';
COMMENT ON COLUMN engine_postgresql.publication_table_columns.position IS 'its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
