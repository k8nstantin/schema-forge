-- engine_mysql.databases: what MySQL says of a database (a namespace) beyond the cortex. Owner: mysql.
CREATE TABLE engine_mysql.databases (
  id           UUID NOT NULL PRIMARY KEY,                                                                     -- the database
  design       UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  "collation"  TEXT NOT NULL,                                                                                 -- its default collation; its character set is the collation's
  encryption   BOOLEAN,                                                                                       -- its default encryption (8.0 and later); NULL before
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_mysql.databases IS 'what MySQL says of a database (a namespace) beyond the cortex.';
COMMENT ON COLUMN engine_mysql.databases.id IS 'the database';
COMMENT ON COLUMN engine_mysql.databases.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_mysql.databases."collation" IS 'its default collation; its character set is the collation''s';
COMMENT ON COLUMN engine_mysql.databases.encryption IS 'its default encryption (8.0 and later); NULL before';
