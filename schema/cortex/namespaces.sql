-- cortex.namespaces: the levels that hold objects, each under its parent or at the top: a MySQL database; a PostgreSQL database and its schemas.
CREATE TABLE cortex.namespaces (
  id        UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row, kept when the name changes
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  parent    UUID,                                                                                            -- the namespace it is in; NULL at the top
  name      TEXT NOT NULL CHECK (length(name) >= 1),                                                         -- as the engine names it (sales)
  position  NUMERIC NOT NULL CHECK (position > 0),                                                           -- its place among its parent's namespaces, in the order made or read; one put between two takes their midpoint
  comment   TEXT,                                                                                            -- what it holds: written into its SQL
  UNIQUE (design, id),
  UNIQUE NULLS NOT DISTINCT (design, parent, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE NULLS NOT DISTINCT (design, parent, position) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, parent) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX namespaces_parent ON cortex.namespaces (design, parent);
