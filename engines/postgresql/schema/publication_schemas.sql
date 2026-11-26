-- engine_postgresql.publication_schemas: the schemas a publication publishes every table of (FOR TABLES IN SCHEMA), PostgreSQL 15 and later. Owner: postgresql.
CREATE TABLE engine_postgresql.publication_schemas (
  id           UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),              -- UUIDv7, made with the row
  design       UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, -- the design it belongs to
  publication  UUID NOT NULL,                                                                                -- the publication
  namespace    UUID NOT NULL,                                                                                -- the schema
  position     NUMERIC NOT NULL CHECK (position > 0),                                                        -- its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  UNIQUE (design, id),
  FOREIGN KEY (design, publication) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, namespace) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX publication_schemas_publication ON engine_postgresql.publication_schemas (design, publication);
CREATE INDEX publication_schemas_namespace ON engine_postgresql.publication_schemas (design, namespace);

COMMENT ON TABLE engine_postgresql.publication_schemas IS 'the schemas a publication publishes every table of (FOR TABLES IN SCHEMA), PostgreSQL 15 and later.';
COMMENT ON COLUMN engine_postgresql.publication_schemas.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.publication_schemas.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.publication_schemas.publication IS 'the publication';
COMMENT ON COLUMN engine_postgresql.publication_schemas.namespace IS 'the schema';
COMMENT ON COLUMN engine_postgresql.publication_schemas.position IS 'its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
