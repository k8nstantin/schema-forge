-- engine_postgresql.publication_tables: the tables a publication publishes (CREATE PUBLICATION ... FOR TABLE), each with its row filter; a table the design holds is a reference, one it does not its name. Owner: postgresql.
CREATE TABLE engine_postgresql.publication_tables (
  id           UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),              -- UUIDv7, made with the row
  design       UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, -- the design it belongs to
  publication  UUID NOT NULL,                                                                                -- the publication
  "table"      UUID,                                                                                         -- the table published; NULL when named instead
  table_name   TEXT CHECK (length(table_name) >= 1),                                                         -- the table by schema.name, where the design does not hold it; NULL when table is set
  row_filter   TEXT,                                                                                         -- its WHERE, as PostgreSQL writes it; NULL for every row
  position     NUMERIC NOT NULL CHECK (position > 0),                                                        -- its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  CHECK (num_nonnulls("table", table_name) = 1),
  UNIQUE (design, id),
  FOREIGN KEY (design, publication) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "table") REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX publication_tables_publication ON engine_postgresql.publication_tables (design, publication);
CREATE INDEX publication_tables_table ON engine_postgresql.publication_tables (design, "table");

COMMENT ON TABLE engine_postgresql.publication_tables IS 'the tables a publication publishes (CREATE PUBLICATION ... FOR TABLE), each with its row filter; a table the design holds is a reference, one it does not its name.';
COMMENT ON COLUMN engine_postgresql.publication_tables.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.publication_tables.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.publication_tables.publication IS 'the publication';
COMMENT ON COLUMN engine_postgresql.publication_tables."table" IS 'the table published; NULL when named instead';
COMMENT ON COLUMN engine_postgresql.publication_tables.table_name IS 'the table by schema.name, where the design does not hold it; NULL when table is set';
COMMENT ON COLUMN engine_postgresql.publication_tables.row_filter IS 'its WHERE, as PostgreSQL writes it; NULL for every row';
COMMENT ON COLUMN engine_postgresql.publication_tables.position IS 'its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
