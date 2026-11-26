-- engine_postgresql.relations: what PostgreSQL says of a table, view, materialized view or sequence beyond the cortex. Owner: postgresql.
CREATE TABLE engine_postgresql.relations (
  id                  BIGINT NOT NULL PRIMARY KEY,                                                                          -- the relation
  design              UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,         -- the design it belongs to
  persistence         TEXT NOT NULL DEFAULT 'permanent' CHECK (persistence IN ('permanent', 'unlogged', 'temporary')),      -- how it is kept
  options             JSONB,                                                                                                -- its storage options as the server writes them (["fillfactor=70"]); NULL for none
  access_method       TEXT,                                                                                                 -- its table access method (heap); NULL for the default
  owner               TEXT,                                                                                                 -- its owner, by role name; NULL for the one the schema is written as
  acl                 JSONB,                                                                                                -- its privileges, as the server writes them; NULL for the defaults
  row_security        BOOLEAN NOT NULL DEFAULT false,                                                                       -- true when its policies apply (ENABLE ROW LEVEL SECURITY)
  force_row_security  BOOLEAN NOT NULL DEFAULT false,                                                                       -- true when they apply to its owner too
  replica_identity    TEXT NOT NULL DEFAULT 'default' CHECK (replica_identity IN ('default', 'nothing', 'full', 'index')),  -- what identifies a row to logical replication
  populated           BOOLEAN NOT NULL DEFAULT true,                                                                        -- for a materialized view, false when made WITH NO DATA
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_postgresql.relations IS 'what PostgreSQL says of a table, view, materialized view or sequence beyond the cortex.';
COMMENT ON COLUMN engine_postgresql.relations.id IS 'the relation';
COMMENT ON COLUMN engine_postgresql.relations.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.relations.persistence IS 'how it is kept';
COMMENT ON COLUMN engine_postgresql.relations.options IS 'its storage options as the server writes them (["fillfactor=70"]); NULL for none';
COMMENT ON COLUMN engine_postgresql.relations.access_method IS 'its table access method (heap); NULL for the default';
COMMENT ON COLUMN engine_postgresql.relations.owner IS 'its owner, by role name; NULL for the one the schema is written as';
COMMENT ON COLUMN engine_postgresql.relations.acl IS 'its privileges, as the server writes them; NULL for the defaults';
COMMENT ON COLUMN engine_postgresql.relations.row_security IS 'true when its policies apply (ENABLE ROW LEVEL SECURITY)';
COMMENT ON COLUMN engine_postgresql.relations.force_row_security IS 'true when they apply to its owner too';
COMMENT ON COLUMN engine_postgresql.relations.replica_identity IS 'what identifies a row to logical replication';
COMMENT ON COLUMN engine_postgresql.relations.populated IS 'for a materialized view, false when made WITH NO DATA';
