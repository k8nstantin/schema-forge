-- engine_mysql.database_options: what MySQL says of a database (a namespace) beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.database_options (
  id           TEXT NOT NULL PRIMARY KEY REFERENCES cortex.namespaces (id) ON DELETE CASCADE,  -- the database
  charset      TEXT,                                                                           -- its default character set (DEFAULT CHARACTER SET); NULL when not written
  "collation"  TEXT                                                                            -- its default collation (DEFAULT COLLATE); NULL when not written
);

COMMENT ON TABLE engine_mysql.database_options IS 'what MySQL says of a database (a namespace) beyond the cortex. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.database_options.id IS 'the database';
COMMENT ON COLUMN engine_mysql.database_options.charset IS 'its default character set (DEFAULT CHARACTER SET); NULL when not written';
COMMENT ON COLUMN engine_mysql.database_options."collation" IS 'its default collation (DEFAULT COLLATE); NULL when not written';
